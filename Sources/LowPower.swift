import AppKit

/// Режим енергозбереження. macOS дозволяє змінювати його лише адміністратору.
/// За згодою користувача ставиться вузьке правило sudoers: поточному користувачу без пароля дозволено
/// РІВНО дві команди — `pmset -a lowpowermode 0` і `… 1`. Пароль macOS питає один раз, при встановленні правила.
enum LowPower {
    static let rulePath = "/etc/sudoers.d/vyshyvka-bar-lowpower"
    private static let pmset0 = "/usr/bin/pmset -a lowpowermode 0", pmset1 = "/usr/bin/pmset -a lowpowermode 1"

    static var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var passwordless: Bool { FileManager.default.fileExists(atPath: rulePath) }
    /// Користувач сам прибрав дозвіл у меню ◆ — тоді пароль питається щоразу, як він і хотів.
    /// (Позначки lowPowerAsked/lowPowerDeclined зі старих версій ігноруються.)
    private static let declinedKey = "lowPowerRuleRemoved"
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

    /// Shell-команда, що (після перевірки visudo) ставить правило «без пароля». nil — якщо ім'я користувача незвичне.
    private static func installScript() -> (String, String)? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        let rule = "# VYSHYVKA BAR: Low Power Mode without a password (only these two commands)\n"
            + "\(user) ALL=(root) NOPASSWD: \(pmset0), \(pmset1)\n"
        let tmp = NSTemporaryDirectory() + "vyshyvka-lowpower.sudoers"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return nil }
        return ("/bin/mkdir -p /private/etc/sudoers.d && /usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(rulePath)'", tmp)
    }

    /// Перемкнути (у фоні). Якщо правило працює — одразу, без пароля.
    /// Якщо ні — macOS питає пароль ОДИН раз: тією ж командою ставиться правило і перемикається режим,
    /// тож далі пароль більше не потрібен.
    static func toggle(done: @escaping () -> Void) {
        let on = !isOn, cmd = on ? pmset1 : pmset0
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false, how = "sudo"
            if sudoWorks(cmd) { ok = run("/usr/bin/sudo", ["-n"] + cmd.split(separator: " ").map(String.init)) == 0 }
            if !ok {
                let prompt = on ? L.t("VYSHYVKA BAR вмикає режим енергозбереження.", "VYSHYVKA BAR is turning on Low Power Mode.")
                                : L.t("VYSHYVKA BAR вимикає режим енергозбереження.", "VYSHYVKA BAR is turning off Low Power Mode.")
                if !declined, let (install, tmp) = installScript() {
                    how = "install+switch"
                    // Режим перемикається, навіть якщо правило з якоїсь причини не стало.
                    ok = admin("{ \(install); } ; \(cmd)", prompt: prompt + " " + L.t("Пароль потрібен лише цього разу.", "The password is needed only this once."))
                    try? FileManager.default.removeItem(atPath: tmp)
                } else {
                    how = "admin"
                    ok = admin(cmd, prompt: prompt)
                }
            }
            hwLog.notice("low power → \(on, privacy: .public): \(ok ? "ok" : "failed", privacy: .public) via \(how, privacy: .public), rule works: \(sudoWorks(pmset1), privacy: .public)")
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Пункт меню: поставити правило «без пароля» (macOS один раз питає пароль).
    static func enablePasswordless(done: @escaping (Bool) -> Void) {
        guard let (install, tmp) = installScript() else { return done(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = admin(install, prompt: L.t("VYSHYVKA BAR: дозволити перемикати енергозбереження без пароля.",
                                                "VYSHYVKA BAR: allow switching Low Power Mode without a password."))
            try? FileManager.default.removeItem(atPath: tmp)
            if ok { declined = false }
            hwLog.notice("low power rule installed from menu: \(ok, privacy: .public)")
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
}
