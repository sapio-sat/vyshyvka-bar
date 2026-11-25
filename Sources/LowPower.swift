import AppKit

/// Режим енергозбереження. macOS дозволяє змінювати його лише адміністратору.
/// За згодою користувача ставиться вузьке правило sudoers: поточному користувачу без пароля дозволено
/// РІВНО дві команди — `pmset -a lowpowermode 0` і `… 1`. Пароль macOS питає один раз, при встановленні правила.
enum LowPower {
    static let rulePath = "/etc/sudoers.d/vyshyvka-bar-lowpower"
    private static let pmset0 = "/usr/bin/pmset -a lowpowermode 0", pmset1 = "/usr/bin/pmset -a lowpowermode 1"

    static var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var passwordless: Bool { FileManager.default.fileExists(atPath: rulePath) }
    /// Користувач свідомо обрав «Питати пароль щоразу». Стара позначка lowPowerAsked ігнорується:
    /// у 1.4.0 вона ставилась ще до відповіді, і скасоване вікно пароля назавжди вимикало пропозицію.
    private static let declinedKey = "lowPowerDeclined"
    static var declined: Bool {
        get { UserDefaults.standard.bool(forKey: declinedKey) }
        set { UserDefaults.standard.set(newValue, forKey: declinedKey) }
    }
    /// Чи справді sudo пропускає команду без пароля (файл може бути, а правило — не діяти).
    private static func sudoWorks(_ cmd: String) -> Bool {
        run("/usr/bin/sudo", ["-n", "-l"] + cmd.split(separator: " ").map(String.init)) == 0
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    private static func admin(_ shell: String, prompt: String) -> Bool {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"]) == 0
    }

    /// Перемкнути (у фоні). Без правила — з паролем, з правилом — одразу.
    static func toggle(done: @escaping () -> Void) {
        let on = !isOn
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            if passwordless, sudoWorks(on ? pmset1 : pmset0) { ok = run("/usr/bin/sudo", ["-n"] + (on ? pmset1 : pmset0).split(separator: " ").map(String.init)) == 0 }
            if !ok {
                ok = admin(on ? pmset1 : pmset0, prompt: on ? L.t("VYSHYVKA BAR вмикає режим енергозбереження.", "VYSHYVKA BAR is turning on Low Power Mode.")
                                                           : L.t("VYSHYVKA BAR вимикає режим енергозбереження.", "VYSHYVKA BAR is turning off Low Power Mode."))
            }
            hwLog.notice("low power → \(on): \(ok ? "ok" : "failed"), passwordless=\(passwordless)")
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Встановити правило «без пароля» (macOS один раз питає пароль). Перевіряється visudo перед встановленням.
    /// `alsoSwitchTo` — одразу ж перемкнути режим тією самою командою, щоб пароль питався рівно один раз.
    static func enablePasswordless(alsoSwitchTo: Bool? = nil, done: @escaping (Bool) -> Void) {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return done(false) }
        let rule = "# VYSHYVKA BAR: перемикання режиму енергозбереження без пароля (лише ці дві команди)\n"
            + "\(user) ALL=(root) NOPASSWD: \(pmset0), \(pmset1)\n"
        let tmp = NSTemporaryDirectory() + "vyshyvka-lowpower.sudoers"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return done(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            var sh = "/bin/mkdir -p /private/etc/sudoers.d && /usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(rulePath)'"
            if let on = alsoSwitchTo { sh += " && " + (on ? pmset1 : pmset0) }
            let ok = admin(sh,
                           prompt: L.t("VYSHYVKA BAR: дозволити перемикати енергозбереження без пароля.",
                                       "VYSHYVKA BAR: allow switching Low Power Mode without a password."))
            try? FileManager.default.removeItem(atPath: tmp)
            hwLog.notice("low power passwordless rule installed: \(ok), works: \(ok && sudoWorks(pmset1))")
            if ok { declined = false }
            DispatchQueue.main.async { done(ok) }
        }
    }

    static func disablePasswordless(done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = admin("/bin/rm -f '\(rulePath)'", prompt: L.t("VYSHYVKA BAR: прибрати дозвіл без пароля.", "VYSHYVKA BAR: remove the no-password permission."))
            if ok { declined = true }   // прибрали свідомо — не пропонувати знову
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Тап по батареї без правила: запропонувати дозволити «без пароля».
    /// Питає, доки правило не встановлено, — хіба що користувач свідомо обрав «Питати пароль щоразу».
    static func askIfNeeded() -> Bool {
        guard !passwordless, !declined else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L.t("Перемикати енергозбереження без пароля?", "Switch Low Power Mode without a password?")
        a.informativeText = L.t("macOS дозволяє змінювати цей режим лише адміністратору, тому без дозволу пароль питатиметься щоразу.\n\nЯкщо дозволити, macOS один раз попросить пароль і додасть вузьке правило: вашому користувачу без пароля дозволено лише вмикати й вимикати енергозбереження, більше нічого. Прибрати можна в меню ◆.",
                                "macOS only lets administrators change this mode, so without permission you'll be asked for a password every time.\n\nIf you allow it, macOS asks for your password once and adds a narrow rule: your account may switch Low Power Mode on and off without a password, nothing else. You can remove it from the ◆ menu.")
        a.addButton(withTitle: L.t("Дозволити", "Allow"))
        a.addButton(withTitle: L.t("Питати пароль щоразу", "Ask every time"))
        let allow = a.runModal() == .alertFirstButtonReturn
        if !allow { declined = true }
        return allow
    }
}
