import AppKit
import AudioToolbox
import CoreAudio
import IOKit
import IOKit.graphics

// V5: яркость и громкость меняются напрямую через системные API с чтением значения
// до/после, а не синтетическими медиа-клавишами (те зависели от Accessibility
// и молча терялись). Шаг 1/16 — как у физических клавиш.

let hardwareStep: Float = 1.0 / 16.0

struct StepResult: CustomStringConvertible {
    var before: Float?
    var after: Float?
    var target: String
    var error: String?
    var changed: Bool { if let b = before, let a = after { return abs(a - b) > 0.001 } else { return false } }
    var description: String {
        let f = { (v: Float?) in v.map { String(format: "%.4f", $0) } ?? "nil" }
        return "\(target): \(f(before)) → \(f(after))" + (error.map { " [\($0)]" } ?? "")
    }
}

// MARK: - Громкость (Core Audio, текущее устройство вывода)

enum Volume {
    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                             _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    /// Каждый раз заново — после смены устройства вывода не держим устаревший handle.
    static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    static func name(_ id: AudioDeviceID) -> String {
        var name: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size)
        var a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return name as String
    }

    private static var mainVolume: AudioObjectPropertyAddress {
        addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    }

    static func settable(_ id: AudioDeviceID) -> Bool {
        var a = mainVolume
        guard AudioObjectHasProperty(id, &a) else { return false }
        var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &s) == noErr && s.boolValue
    }

    static func get(_ id: AudioDeviceID) -> Float? {
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size), a = mainVolume
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func set(_ id: AudioDeviceID, _ value: Float) -> OSStatus {
        var v = Float32(min(1, max(0, value))), a = mainVolume
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func muted(_ id: AudioDeviceID) -> Bool {
        var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size), a = addr(kAudioDevicePropertyMute)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &m) == noErr && m != 0
    }

    static func setMuted(_ id: AudioDeviceID, _ on: Bool) {
        var m = UInt32(on ? 1 : 0), a = addr(kAudioDevicePropertyMute)
        var s: DarwinBoolean = false
        if AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &s) == noErr, s.boolValue {
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    @discardableResult
    static func step(_ dir: Float) -> StepResult {
        guard let id = device() else { return StepResult(target: "audio", error: "нет устройства вывода") }
        let n = name(id)
        guard settable(id) else {
            return StepResult(before: get(id), target: n, error: "устройство не поддерживает программную громкость")
        }
        let before = get(id)
        let b = before ?? 0
        // как у клавиатуры: квантование к сетке 1/16
        let target = min(1, max(0, (round(b / hardwareStep) + dir) * hardwareStep))
        if dir > 0, muted(id) { setMuted(id, false) }
        let err = set(id, target)
        if dir < 0, target <= 0.0001 { setMuted(id, true) }
        return StepResult(before: before, after: get(id), target: n, error: err == noErr ? nil : "OSStatus \(err)")
    }
}

// MARK: - Яркость встроенного дисплея (аппаратная подсветка)

enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias NotifyFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    // DisplayServices — приватный фреймворк macOS (через него работают системные клавиши
    // и Control Center). Загружается динамически: при отсутствии символов — IOKit.
    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let ds = ds, let p = dlsym(ds, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let dsGet = sym("DisplayServicesGetBrightness", GetFn.self)
    private static let dsSet = sym("DisplayServicesSetBrightness", SetFn.self)
    private static let dsNotify = sym("DisplayServicesBrightnessChanged", NotifyFn.self)

    static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n = UInt32(0)
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func ioService() -> io_service_t? {
        var it = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        let s = IOIteratorNext(it)
        return s == 0 ? nil : s
    }

    static var method: String {
        if dsGet != nil && dsSet != nil { return "DisplayServices" }
        return ioService() != nil ? "IOKit IODisplay" : "нет"
    }

    static func get() -> Float? {
        guard let d = builtinDisplay() else { return nil }
        if let g = dsGet {
            var v: Float = 0
            if g(d, &v) == 0 { return v }
        }
        if let s = ioService() {
            defer { IOObjectRelease(s) }
            var v: Float = 0
            if IODisplayGetFloatParameter(s, 0, kIODisplayBrightnessKey as CFString, &v) == kIOReturnSuccess { return v }
        }
        return nil
    }

    static func set(_ value: Float) -> String? {
        guard let d = builtinDisplay() else { return "встроенный дисплей не найден (крышка закрыта?)" }
        let v = min(1, max(0, value))
        if let s = dsSet {
            let r = s(d, v)
            if r == 0 { _ = dsNotify?(d, v); return nil }
            return "DisplayServicesSetBrightness = \(r)"
        }
        if let svc = ioService() {
            defer { IOObjectRelease(svc) }
            let r = IODisplaySetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, v)
            return r == kIOReturnSuccess ? nil : "IODisplaySetFloatParameter = \(r)"
        }
        return "нет доступного механизма"
    }

    @discardableResult
    static func step(_ dir: Float) -> StepResult {
        let before = get()
        guard let b = before else { return StepResult(target: "built-in display", error: "яркость не читается") }
        let target = min(1, max(0, (round(b / hardwareStep) + dir) * hardwareStep))
        let err = set(target)
        return StepResult(before: before, after: get(), target: "built-in display (\(method))", error: err)
    }
}
