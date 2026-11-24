import AppKit
import IOKit.hidsystem

/// Нажатия — те же системные события, что от настоящей клавиатуры (нужен Accessibility).
enum Keys {
    static func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func escape() { press(53) }

    /// ⌃⇧⌘4 — системное выделение области с копированием в буфер (без файла).
    static func screenshotToClipboard() { press(21, flags: [.maskControl, .maskShift, .maskCommand]) }

    /// Медиа-клавиши (яркость/громкость) — NX_SYSDEFINED aux key, как у штатной клавиатуры.
    static func aux(_ key: Int32) {
        for down in [true, false] {
            let flags = down ? NX_KEYDOWN : NX_KEYUP
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                                           data1: (Int(key) << 16) | (Int(flags) << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func brightnessDown() { aux(NX_KEYTYPE_BRIGHTNESS_DOWN) }
    static func brightnessUp()   { aux(NX_KEYTYPE_BRIGHTNESS_UP) }
    static func volumeDown()     { aux(NX_KEYTYPE_SOUND_DOWN) }
    static func volumeUp()       { aux(NX_KEYTYPE_SOUND_UP) }
}
