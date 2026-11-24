import AppKit

/// VYSHYVKA BAR V5 — Artistic Living Embroidery
enum VB {
    static let bg      = NSColor(hex: 0x08080A)
    static let label   = NSColor(hex: 0xEFE8E0)   // подписи
    static let ivory   = NSColor(hex: 0xF1E8DE)   // белая льняная нить
    static let cream   = NSColor(hex: 0xD6BEA4)   // кремовая нить
    static let red     = NSColor(hex: 0xB42D3E)   // вышивальный красный
    static let bordo   = NSColor(hex: 0x8C2233)   // бордовый

    static let barHeight: CGFloat = 30
    /// Ширина панелі: 1085 pt (2170 px) на моделях з Esc на Touch Bar (перевірено screencapture -b на 15" 2019);
    /// на моделях з фізичною Esc сенсорна смуга коротша — 1004 pt (2008 px).
    /// Ручне перевизначення: defaults write ua.vyshyvka.bar barWidth -float 1004
    static let barWidth: CGFloat = {
        let o = UserDefaults.standard.double(forKey: "barWidth")
        if o >= 600 && o <= 1200 { return CGFloat(o) }
        return hasPhysicalEsc ? 1004 : 1085
    }()
    static let stroke: CGFloat = 1.15

    /// Модель Mac (hw.model), напр. «MacBookPro15,1».
    static let model: String = {
        var n = 0; sysctlbyname("hw.model", nil, &n, nil, 0)
        var b = [CChar](repeating: 0, count: max(n, 1)); sysctlbyname("hw.model", &b, &n, nil, 0)
        return String(cString: b)
    }()
    /// Touch Bar-моделі з фізичною клавішею Esc: 16" 2019, 13" 2020 (Intel), 13" M1 (2020), 13" M2 (2022).
    /// На них власна кнопка esc на панелі не потрібна. Перевизначення: defaults write ua.vyshyvka.bar showEsc -bool YES
    static let hasPhysicalEsc: Bool = {
        if let o = UserDefaults.standard.object(forKey: "showEsc") as? Bool { return !o }
        return ["MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4", "MacBookPro17,1", "Mac14,7"].contains(model)
    }()

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)   // табличные цифры
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
