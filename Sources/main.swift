import AppKit
import AVFoundation
import ImageIO
import os
import UniformTypeIdentifiers

let hwLog = Logger(subsystem: "ua.vyshyvka.bar", category: "hardware")

extension NSTouchBarItem.Identifier {
    static let vbBar = NSTouchBarItem.Identifier("ua.vyshyvka.bar.main")
    static let vbTray = NSTouchBarItem.Identifier("ua.vyshyvka.bar.tray")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    let bar = BarView(frame: NSRect(x: 0, y: 0, width: VB.barWidth, height: VB.barHeight))
    let touchBar = NSTouchBar()
    let battery = BatteryMonitor()
    let clock = Clock()
    let weather = WeatherService()
    let inputSource = InputSource()            // без изменений с Premium 3.0
    let hwQueue = DispatchQueue(label: "ua.vyshyvka.bar.hardware")
    var statusItem: NSStatusItem?
    lazy var lossesPanel = LossesPanel()
    lazy var weatherWindow = WeatherWindow()
    lazy var layoutWindow = LayoutWindow()
    let wallpaper = WallpaperController()
    var wallpaperItem: NSMenuItem?
    var cityItem: NSMenuItem?
    var lowPowerItem: NSMenuItem?
    var welcome: WelcomeWindow?

    func applicationDidFinishLaunching(_: Notification) {
        // Accessibility нужен только esc и скриншоту. Без системного диалога при каждом запуске:
        // только проверка; тап по приглушённым esc/скриншоту откроет нужный раздел настроек.
        bar.accessibilityTrusted = AXIsProcessTrusted()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(axChanged),
                                                            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        hwLog.notice("launch: AX trusted=\(self.bar.accessibilityTrusted), brightness via \(Brightness.method, privacy: .public)")

        bar.onAction = { [weak self] c in self?.perform(c) }
        battery.onChange = { [weak self] in self?.bar.battery = $0 }
        clock.onChange = { [weak self] in self?.bar.time = $0 }
        weather.onChange = { [weak self] in self?.bar.weather = $0 }
        inputSource.onChange = { [weak self] in self?.bar.input = $0 }
        battery.start(); clock.start(); weather.start(); inputSource.start()

        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.vbBar]
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        let tray = NSCustomTouchBarItem(identifier: .vbTray)
        tray.view = NSButton(title: "◆", target: self, action: #selector(present))
        NSTouchBarItem.addSystemTrayItem(tray)
        DFRElementSetControlStripPresenceForIdentifier(.vbTray, true)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(present), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(motionPrefChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        setupStatusItem()
        wallpaper.start()
        hwLog.notice("wallpaper windows: \(self.wallpaper.windowNumbers, privacy: .public) mode: \(self.wallpaper.modes, privacy: .public)")
        present()
        motionPrefChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(cityChanged), name: City.changed, object: nil)
        NotificationCenter.default.addObserver(forName: BarLayout.changed, object: nil, queue: .main) { [weak self] _ in self?.bar.relayout() }
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            if City.saved != nil { UserDefaults.standard.set(true, forKey: "onboarded") }   // оновлення зі старої версії
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openSettings(first: true) } }
        }
    }

    func openSettings(first: Bool) {
        let w = WelcomeWindow(wallpaper: wallpaper, firstLaunch: first)
        w.onFinish = { [weak self] in self?.welcome = nil }
        w.onLayout = { [weak self] in self?.showLayout() }
        welcome = w
        w.show()
    }
    @objc func openSettingsMenu() { openSettings(first: false) }
    @objc func cityChanged() { cityItem?.title = L.t("Місто погоди: ", "Weather city: ") + City.current.name }

    func touchBar(_: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == .vbBar else { return nil }
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = bar
        // Ширина Touch Bar різниться між моделями: просимо повну, але погоджуємося на ту, що дає система.
        let want = bar.widthAnchor.constraint(equalToConstant: VB.barWidth)
        want.priority = .defaultLow
        NSLayoutConstraint.activate([want, bar.widthAnchor.constraint(lessThanOrEqualToConstant: VB.barWidth),
                                     bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 640)])
        item.visibilityPriority = .high
        return item
    }

    @objc func present() { NSTouchBar.presentSystemModalTouchBar(touchBar, placement: 1, systemTrayItemIdentifier: .vbTray) }
    @objc func screensSleep() { bar.hideForecast(); bar.stopMotion() }
    @objc func screensWake() { present(); motionPrefChanged() }
    @objc func motionPrefChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { bar.stopMotion(staticTime: 6.0) } else { bar.startMotion() }
    }
    @objc func axChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.bar.accessibilityTrusted = AXIsProcessTrusted() }
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func hardware(_ c: BarView.Control, _ step: @escaping () -> StepResult) {
        hwQueue.async {
            let r = step()
            hwLog.notice("\(String(describing: c), privacy: .public): \(r.description, privacy: .public)")
            DispatchQueue.main.async {
                self.bar.showLevel(r.after, for: c)
                if let v = r.after, UserDefaults.standard.object(forKey: "screenHUD") as? Bool ?? true {
                    LevelHUD.shared.show(c == .volumeUp || c == .volumeDown ? .volume : .brightness, value: v)
                }
            }
        }
    }

    func perform(_ c: BarView.Control) {
        switch c {
        case .esc, .shot:
            let trusted = AXIsProcessTrusted()
            bar.accessibilityTrusted = trusted
            guard trusted else {
                // Регистрирует приложение (с текущей подписью) в списке «Доступность» и показывает
                // системный запрос; остаётся только включить переключатель.
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                hwLog.notice("\(String(describing: c), privacy: .public): Accessibility not granted, prompt shown")
                openAccessibilitySettings()
                return
            }
            c == .esc ? Keys.escape() : Keys.screenshotToClipboard()
        case .brightnessDown: hardware(c) { Brightness.step(-1) }
        case .brightnessUp:   hardware(c) { Brightness.step(+1) }
        case .volumeDown:     hardware(c) { Volume.step(-1) }
        case .volumeUp:       hardware(c) { Volume.step(+1) }
        case .input: inputSource.next()
        case .trident: lossesPanel.toggle()
        case .weather: bar.showForecast()
        case .back: bar.hideForecast()
        case .details: bar.hideForecast(); showWeather()
        case .clock: openCalendar()
        case .battery: toggleLowPower()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "◆"
        item.button?.toolTip = "VYSHYVKA BAR"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L.t("Показати панель Touch Bar", "Show Touch Bar panel"), action: #selector(present), keyEquivalent: "").target = self
        menu.addItem(withTitle: L.t("Зведення Генштабу ЗСУ", "Ukraine General Staff report"), action: #selector(showLosses), keyEquivalent: "").target = self
        menu.addItem(withTitle: L.t("Погода на тиждень", "Weekly weather"), action: #selector(showWeather), keyEquivalent: "").target = self
        let wp = menu.addItem(withTitle: L.t("Живі шпалери", "Live wallpaper"), action: #selector(toggleWallpaper), keyEquivalent: "")
        wp.target = self
        wp.state = wallpaper.enabled ? .on : .off
        wallpaperItem = wp
        menu.addItem(.separator())
        let ci = menu.addItem(withTitle: "", action: #selector(openSettingsMenu), keyEquivalent: "")
        ci.target = self
        cityItem = ci
        cityChanged()
        menu.addItem(withTitle: L.t("Елементи панелі…", "Bar items…"), action: #selector(showLayout), keyEquivalent: "").target = self
        let lp = menu.addItem(withTitle: L.t("Енергозбереження без пароля", "Low Power Mode without password"), action: #selector(togglePasswordless), keyEquivalent: "")
        lp.target = self
        lp.state = LowPower.passwordless ? .on : .off
        lowPowerItem = lp
        menu.addItem(withTitle: L.t("Налаштування…", "Settings…"), action: #selector(openSettingsMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("Вийти — повернути стандартний Touch Bar", "Quit — restore standard Touch Bar"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc func showLosses() { lossesPanel.present() }
    /// Системний «Календар» на сьогоднішньому дні.
    func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            }
        }
    }
    func toggleLowPower() {
        let refresh: () -> Void = { [weak self] in self?.bar.battery = BatteryMonitor.read(); self?.lowPowerItem?.state = LowPower.passwordless ? .on : .off }
        if LowPower.askIfNeeded() {
            // Одне вікно пароля: правило + перемикання. Якщо скасовано — наступного тапу запропонуємо знову.
            LowPower.enablePasswordless(alsoSwitchTo: !LowPower.isOn) { _ in refresh() }
        } else {
            LowPower.toggle(done: refresh)
        }
    }
    @objc func togglePasswordless() {
        let refresh: (Bool) -> Void = { [weak self] _ in self?.lowPowerItem?.state = LowPower.passwordless ? .on : .off }
        LowPower.passwordless ? LowPower.disablePasswordless(done: refresh) : LowPower.enablePasswordless(done: refresh)
    }
    @objc func showLayout() { layoutWindow.show() }
    @objc func showWeather() { weatherWindow.show(weather.latest ?? bar.weather) }
    @objc func toggleWallpaper() {
        wallpaper.enabled.toggle()
        wallpaperItem?.state = wallpaper.enabled ? .on : .off
    }
    func menuNeedsUpdate(_: NSMenu) {
        wallpaperItem?.state = wallpaper.enabled ? .on : .off
        lowPowerItem?.state = LowPower.passwordless ? .on : .off
    }

    func applicationWillTerminate(_: Notification) { NSTouchBar.dismissSystemModalTouchBar(touchBar) }
}

// MARK: - Нативный предпросмотр (тот же BarView/Embroidery, без вывода на Touch Bar)
//   VyshyvkaBar --render out.png [t]          кадр на момент t (с)
//   VyshyvkaBar --frames dir [n]              n кадров цикла (PNG, 2170×60)
//   VyshyvkaBar --mp4 out.mp4 [sec] [fps] [scale]
//   VyshyvkaBar --stats
enum RenderTool {
    static func makeBar() -> BarView {
        let b = BarView(frame: NSRect(x: 0, y: 0, width: VB.barWidth, height: VB.barHeight))
        b.relayout()
        b.battery = BatteryMonitor.read()
        let f = DateFormatter(); f.dateFormat = "HH:mm"; b.time = f.string(from: Date())
        b.input = InputSource.currentLabel()
        let sem = DispatchSemaphore(value: 0)
        var w: Weather?
        URLSession.shared.dataTask(with: WeatherService.url) { d, _, _ in w = d.flatMap(WeatherService.parse); sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 10)
        b.weather = w
        b.accessibilityTrusted = true
        return b
    }

    static func png(_ img: CGImage, _ path: String) {
        let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func mp4(_ b: BarView, path: String, seconds: Double, fps: Int, scale: CGFloat) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let w = Int(VB.barWidth * scale) & ~1, h = Int(VB.barHeight * scale) & ~1
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let n = Int(seconds * Double(fps))
        for i in 0..<n {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            let img = b.snapshot(time: Double(i) / Double(fps), scale: scale)
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        print("mp4: \(path) \(n) frames @\(fps) fps, \(w)×\(h)")
    }

    static func run(_ a: [String]) -> Int32 {
        let b = makeBar()
        func arg(_ k: String, _ off: Int) -> String? { a.firstIndex(of: k).flatMap { $0 + off < a.count ? a[$0 + off] : nil } }
        if a.contains("--stats") {
            print("layers: \(b.embroidery.layerCount), animated tracks: \(b.embroidery.tracks.count)")
        }
        if let p = arg("--forecast", 1) {          // кадр прогнозу на Touch Bar
            b.showForecast(); b.applyForecastVisibility()
            png(b.snapshot(time: 6), p); print("png: \(p) forecast")
        }
        if let p = arg("--render", 1) {
            let t = Double(arg("--render", 2) ?? "6") ?? 6
            png(b.snapshot(time: t), p); print("png: \(p) t=\(t)s")
        }
        if let dir = arg("--frames", 1) {
            let n = Int(arg("--frames", 2) ?? "5") ?? 5
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for i in 0...n {
                let t = Embroidery.period * Double(i) / Double(n)
                png(b.snapshot(time: t), "\(dir)/frame-\(String(format: "%03d", Int((Double(i) / Double(n)) * 100)))pct.png")
            }
            print("frames: \(n + 1) → \(dir)")
        }
        if let p = arg("--mp4", 1) {
            mp4(b, path: p, seconds: Double(arg("--mp4", 2) ?? "12") ?? 12, fps: Int(arg("--mp4", 3) ?? "30") ?? 30,
                scale: CGFloat(Double(arg("--mp4", 4) ?? "2") ?? 2))
        }
        return 0
    }
}

let args = CommandLine.arguments
// Рендер зацикленого ролика шпалер під розмір головного екрана (один раз; потім просто програється)
//   VyshyvkaBar --wallpaper-video [out.mov]        VyshyvkaBar --wallpaper-frame out.png t
if args.contains("--wallpaper-video") || args.contains("--wallpaper-frame") {
    _ = NSApplication.shared
    let size = NSScreen.main?.frame.size ?? CGSize(width: 1680, height: 1050)
    if let i = args.firstIndex(of: "--wallpaper-frame"), i + 1 < args.count {
        let t = i + 2 < args.count ? Double(args[i + 2]) ?? 6 : 6
        let scene = WallpaperScene(frame: NSRect(origin: .zero, size: size))
        let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        let t0 = Date(); scene.render(at: t, in: ctx)
        RenderTool.png(ctx.makeImage()!, args[i + 1]); print("frame \(args[i + 1]) t=\(t) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        exit(0)
    }
    let i = args.firstIndex(of: "--wallpaper-video")!
    var jobs: [(CGSize, URL)] = []
    if i + 1 < args.count { jobs = [(size, URL(fileURLWithPath: args[i + 1]))] }
    else {   // без шляху: усі екрани, для яких ролика ще немає
        for s in Set(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }) {
            let p = s.split(separator: "x").map { CGFloat(Int($0)!) }
            let sz = CGSize(width: p[0], height: p[1]), u = WallpaperVideo.url(for: sz)
            if !FileManager.default.fileExists(atPath: u.path) { jobs.append((sz, u)) }
        }
    }
    do {
        for (sz, out) in jobs {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = out.deletingPathExtension().appendingPathExtension("partial.mov")
            try? FileManager.default.removeItem(at: tmp)
            try WallpaperVideo.render(size: sz, to: tmp) { k, n in if k % 90 == 0 { print("\(k)/\(n)"); fflush(stdout) } }
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: tmp, to: out)
            print("video: \(out.path)")
        }
        exit(0)
    } catch { print("error: \(error)"); exit(1) }
}
if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    _ = NSApplication.shared
    let sz = i + 2 < args.count ? CGFloat(Double(args[i + 2]) ?? 1024) : 1024
    RenderTool.png(AppIcon.render(size: sz), args[i + 1]); exit(0)
}
if args.contains("--disable-login-item") {   // прибрати автозапуск без UI
    print(LoginItem.set(false) ? "login item removed" : "login item: nothing to remove"); exit(0)
}
if args.contains("--welcome-window") {   // предпросмотр вікна привітання (нічого не зберігає)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let w = WelcomeWindow(wallpaper: WallpaperController(), firstLaunch: true)
    w.show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("window:\(w.windowNumber)"); fflush(stdout) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}
if args.contains("--losses-window") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = LossesPanel()
    panel.present()
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("window:\(panel.windowNumber)"); fflush(stdout) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
    app.run()
}
if let i = args.firstIndex(of: "--weather-window") {   // предпросмотр вікна погоди
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var w: Weather?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: WeatherService.url) { d, _, _ in w = d.flatMap(WeatherService.parse); sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 10)
    let win = WeatherWindow()
    win.show(w)
    _ = i
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("window:\(win.windowNumber)"); fflush(stdout) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}
if let i = args.firstIndex(of: "--hud") {     // предпросмотр індикатора: --hud volume|brightness 0.6
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let kind: LevelHUD.Kind = (i + 1 < args.count && args[i + 1] == "brightness") ? .brightness : .volume
    let v = Float(i + 2 < args.count ? args[i + 2] : "0.6") ?? 0.6
    DispatchQueue.main.async { LevelHUD.shared.show(kind, value: v) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("window:\(LevelHUD.shared.windowNumber)"); fflush(stdout) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(0) }
    app.run()
}
if args.contains("--layout-window") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let win = LayoutWindow(); win.show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("window:\(win.windowNumber)"); fflush(stdout) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}
if args.contains("--render") || args.contains("--frames") || args.contains("--forecast") || args.contains("--mp4") || args.contains("--stats") {
    _ = NSApplication.shared
    exit(RenderTool.run(args))
}

let me = Bundle.main.bundleIdentifier ?? "ua.vyshyvka.bar"
if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
