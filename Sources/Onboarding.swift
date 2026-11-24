import AppKit
import ServiceManagement

/// Автозапуск при вході (Login Items, macOS 13+). Без терміналу й LaunchAgent-файлів.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/ua.vyshyvka.bar.plist")
    }
    @discardableResult static func set(_ on: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister(); return true }
        catch { hwLog.error("login item: \(error.localizedDescription, privacy: .public)"); return false }
    }
}

/// Поле міста: вводите будь-яку назву — список під полем показує збіги з усього світу.
final class CityField: NSComboBox, NSComboBoxDelegate, NSComboBoxDataSource {
    private(set) var items: [(City, String)] = []
    private var pending: DispatchWorkItem?
    private var query = ""
    var selected: City?

    override init(frame: NSRect) {
        super.init(frame: frame)
        usesDataSource = true
        dataSource = self
        delegate = self
        completes = false
        numberOfVisibleItems = 10
        placeholderString = L.t("Почніть вводити місто — будь-де у світі", "Start typing any city in the world")
        items = (City.presets + City.world).map { ($0, "") }
        let cur = City.current
        stringValue = cur.name
        selected = cur
    }
    required init?(coder: NSCoder) { fatalError() }

    func numberOfItems(in _: NSComboBox) -> Int { items.count }
    func comboBox(_: NSComboBox, objectValueForItemAt i: Int) -> Any? {
        let (c, d) = items[i]
        return d.isEmpty ? c.name : "\(c.name) — \(d)"
    }

    func comboBoxSelectionDidChange(_: Notification) {
        let i = indexOfSelectedItem
        guard i >= 0, i < items.count else { return }
        selected = items[i].0
    }

    override func textDidChange(_ n: Notification) {
        super.textDidChange(n)
        selected = nil
        let q = stringValue.trimmingCharacters(in: .whitespaces)
        pending?.cancel()
        guard q.count >= 2 else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.query = q
            City.search(q) { [weak self] r in
                guard let self = self, self.query == q, !r.isEmpty else { return }
                self.items = r
                self.reloadData()
                if self.window?.firstResponder == self.currentEditor() {
                    // розкрити список збігів під полем
                    let sel = Selector(("popUp:"))
                    if let c = self.cell as? NSComboBoxCell, c.responds(to: sel) { c.perform(sel, with: nil) }
                }
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// Обране місто: зі списку, або перший збіг для введеного тексту.
    func resolve(_ done: @escaping (City?) -> Void) {
        if let s = selected { return done(s) }
        let q = stringValue.components(separatedBy: " — ").first!.trimmingCharacters(in: .whitespaces)
        if let p = (City.presets + City.world).first(where: { $0.name.lowercased() == q.lowercased() }) { return done(p) }
        guard !q.isEmpty else { return done(nil) }
        City.search(q) { done($0.first?.0) }
    }
}

/// Вікно привітання (перший запуск) — усе налаштування мишкою, без терміналу.
final class WelcomeWindow: NSWindow {
    private let city = CityField(frame: .zero)
    private let wallpaperOurs: NSButton
    private let wallpaperMine: NSButton
    private let loginBox: NSButton
    private let axButton: NSButton
    private let axState = NSTextField(labelWithString: "")
    private let wallpaper: WallpaperController
    private let note = NSTextField(labelWithString: "")
    private let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onFinish: (() -> Void)?
    var onLayout: (() -> Void)?

    init(wallpaper: WallpaperController, firstLaunch: Bool) {
        self.wallpaper = wallpaper
        wallpaperOurs = NSButton(radioButtonWithTitle: L.t("Наші живі шпалери", "Our live wallpaper"), target: nil, action: nil)
        wallpaperMine = NSButton(radioButtonWithTitle: L.t("Залишити мої шпалери", "Keep my wallpaper"), target: nil, action: nil)
        loginBox = NSButton(checkboxWithTitle: L.t("Запускати при вході в систему", "Open at login"), target: nil, action: nil)
        axButton = NSButton(title: L.t("Дозволити…", "Allow…"), target: nil, action: nil)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = VB.bg
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let v = NSView(frame: contentRect(forFrameRect: frame))
        v.wantsLayer = true
        contentView = v

        // тризуб у веселковій гамі + заголовок
        let tr = CAShapeLayer()
        tr.path = Tryzub.path(height: 64, centerX: 270, baseY: 510)
        let grad = CAGradientLayer()
        grad.frame = v.bounds
        grad.colors = Rainbow.stops.reversed().map(\.cgColor)
        grad.startPoint = CGPoint(x: 0.5, y: 510.0 / 620); grad.endPoint = CGPoint(x: 0.5, y: 574.0 / 620)
        grad.mask = tr
        v.layer?.addSublayer(grad)

        let title = label(firstLaunch ? "VYSHYVKA BAR" : L.t("Налаштування", "Settings"), size: 26, weight: .semibold, color: VB.ivory)
        let sub = label(L.t("Жива українська вишивка на вашому Touch Bar", "Living Ukrainian embroidery on your Touch Bar"),
                        size: 13, weight: .regular, color: VB.cream)
        let cityLabel = label(L.t("Місто для погоди", "Weather city"), size: 12, weight: .medium, color: VB.label)
        let axText = label(L.t("Кнопки esc і скріншот потребують дозволу «Універсальний доступ». Яскравість, гучність і погода працюють без нього.",
                               "The esc and screenshot keys need Accessibility permission. Brightness, volume and weather work without it."),
                           size: 11.5, weight: .regular, color: VB.cream)
        axText.preferredMaxLayoutWidth = 300
        axText.maximumNumberOfLines = 0

        let langLabel = label(L.t("Мова інтерфейсу", "Interface language"), size: 12, weight: .medium, color: VB.label)
        langPopup.addItems(withTitles: L.names.map(\.title))
        let curLang = UserDefaults.standard.string(forKey: "uiLanguage") ?? "system"
        langPopup.selectItem(at: L.names.firstIndex { $0.code == curLang } ?? 0)
        langPopup.target = self; langPopup.action = #selector(langChanged)
        let deskLabel = label(L.t("Робочий стіл", "Desktop"), size: 12, weight: .medium, color: VB.label)
        let deskNote = label(L.t("Ваші системні шпалери не змінюються. Вимкнути можна будь-коли: меню ◆ → «Живі шпалери».",
                                 "Your own wallpaper is never changed. Turn it off any time: ◆ menu → “Live wallpaper”."),
                             size: 11, weight: .regular, color: VB.cream.withAlphaComponent(0.8))
        deskNote.preferredMaxLayoutWidth = 250
        wallpaperOurs.state = wallpaper.enabled ? .on : .off
        wallpaperMine.state = wallpaper.enabled ? .off : .on
        let preview = NSImageView()
        preview.image = Bundle.main.image(forResource: "wallpaper-preview")
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8; preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 1; preview.layer?.borderColor = VB.cream.withAlphaComponent(0.25).cgColor
        loginBox.state = (firstLaunch || LoginItem.isEnabled) ? .on : .off
        if #unavailable(macOS 13.0) { loginBox.isEnabled = false }
        for b in [wallpaperOurs, wallpaperMine] { b.target = self; b.action = #selector(radio(_:)) }
        axButton.target = self; axButton.action = #selector(askAX)
        axButton.bezelStyle = .rounded
        note.textColor = VB.red; note.font = .systemFont(ofSize: 11.5)

        let go = NSButton(title: firstLaunch ? L.t("Почати", "Get started") : L.t("Зберегти", "Save"), target: self, action: #selector(finish))
        go.bezelStyle = .rounded; go.keyEquivalent = "\r"; go.controlSize = .large
        let items = NSButton(title: L.t("Елементи панелі…", "Bar items…"), target: self, action: #selector(openLayout))
        items.bezelStyle = .rounded; items.controlSize = .large

        for x in [title, sub, cityLabel, city, langLabel, langPopup, deskLabel, wallpaperOurs, wallpaperMine, deskNote, preview, loginBox, axText, axButton, axState, note, go, items] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor), title.topAnchor.constraint(equalTo: v.topAnchor, constant: 128),
            sub.centerXAnchor.constraint(equalTo: v.centerXAnchor), sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            cityLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 60), cityLabel.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 26),
            city.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), city.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -60),
            city.topAnchor.constraint(equalTo: cityLabel.bottomAnchor, constant: 6),
            langLabel.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), langLabel.centerYAnchor.constraint(equalTo: langPopup.centerYAnchor),
            langPopup.trailingAnchor.constraint(equalTo: city.trailingAnchor), langPopup.topAnchor.constraint(equalTo: city.bottomAnchor, constant: 14),
            langPopup.widthAnchor.constraint(equalToConstant: 200),
            deskLabel.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), deskLabel.topAnchor.constraint(equalTo: langPopup.bottomAnchor, constant: 18),
            wallpaperOurs.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), wallpaperOurs.topAnchor.constraint(equalTo: deskLabel.bottomAnchor, constant: 8),
            wallpaperMine.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), wallpaperMine.topAnchor.constraint(equalTo: wallpaperOurs.bottomAnchor, constant: 6),
            deskNote.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), deskNote.topAnchor.constraint(equalTo: wallpaperMine.bottomAnchor, constant: 6),
            deskNote.widthAnchor.constraint(equalToConstant: 250),
            preview.trailingAnchor.constraint(equalTo: city.trailingAnchor), preview.topAnchor.constraint(equalTo: deskLabel.topAnchor, constant: 2),
            preview.widthAnchor.constraint(equalToConstant: 150), preview.heightAnchor.constraint(equalToConstant: 94),
            loginBox.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), loginBox.topAnchor.constraint(equalTo: deskNote.bottomAnchor, constant: 16),
            axText.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), axText.topAnchor.constraint(equalTo: loginBox.bottomAnchor, constant: 18),
            axText.widthAnchor.constraint(equalToConstant: 300),
            axButton.trailingAnchor.constraint(equalTo: city.trailingAnchor), axButton.centerYAnchor.constraint(equalTo: axText.centerYAnchor),
            axState.trailingAnchor.constraint(equalTo: city.trailingAnchor), axState.centerYAnchor.constraint(equalTo: axText.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: cityLabel.leadingAnchor), note.centerYAnchor.constraint(equalTo: go.centerYAnchor),
            go.trailingAnchor.constraint(equalTo: city.trailingAnchor), go.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -28),
            items.trailingAnchor.constraint(equalTo: go.leadingAnchor, constant: -10), items.centerYAnchor.constraint(equalTo: go.centerYAnchor),
        ])
        axState.textColor = NSColor(hex: 0x37B3A0); axState.font = .systemFont(ofSize: 12, weight: .medium)
        refreshAX()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(axChanged),
                                                            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        center()
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.alignment = .natural
        l.isSelectable = false
        return l
    }

    private func refreshAX() {
        let ok = AXIsProcessTrusted()
        axButton.isHidden = ok
        axState.isHidden = !ok
        axState.stringValue = L.t("✓ Дозволено", "✓ Allowed")
    }
    @objc private func openLayout() { onLayout?() }

    @objc private func langChanged() {
        let code = L.names[langPopup.indexOfSelectedItem].code
        if code == "system" { UserDefaults.standard.removeObject(forKey: "uiLanguage") } else { UserDefaults.standard.set(code, forKey: "uiLanguage") }
        let a = NSAlert()
        a.messageText = L.t("Мова зміниться після перезапуску програми.", "The language changes after the app restarts.")
        a.addButton(withTitle: L.t("Перезапустити", "Restart"))
        a.addButton(withTitle: L.t("Пізніше", "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open '\(path)'"]
        try? p.run()
        NSApp.terminate(nil)
    }
    @objc private func radio(_ b: NSButton) {
        wallpaperOurs.state = b === wallpaperOurs ? .on : .off
        wallpaperMine.state = b === wallpaperMine ? .on : .off
    }
    @objc private func axChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refreshAX() } }

    @objc private func askAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func finish() {
        note.stringValue = L.t("Шукаю місто…", "Looking up the city…")
        city.resolve { [weak self] c in
            guard let self = self else { return }
            guard let c = c else {
                self.note.stringValue = L.t("Місто не знайдено — перевірте назву", "City not found — check the name")
                return
            }
            c.save()
            let ours = self.wallpaperOurs.state == .on
            if self.wallpaper.enabled != ours { self.wallpaper.enabled = ours }
            NotificationCenter.default.post(name: City.changed, object: nil)   // оновити позначки в меню
            if #available(macOS 13.0, *), LoginItem.isEnabled != (self.loginBox.state == .on) { LoginItem.set(self.loginBox.state == .on) }
            UserDefaults.standard.set(true, forKey: "onboarded")
            hwLog.notice("onboarding saved: city=\(c.name, privacy: .public) wallpaper=\(ours) login=\(LoginItem.isEnabled)")
            self.orderOut(nil)
            self.onFinish?()
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
