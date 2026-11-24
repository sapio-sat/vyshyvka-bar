import Foundation

/// Порядок і видимість елементів панелі. Елементи над «вишивкою» — ліворуч, під нею — праворуч.
/// Зберігається в UserDefaults: layoutLeft / layoutRight / layoutHidden.
enum Slot: String, CaseIterable {
    case esc, shot, brightness, volume, battery, clock, weather, input

    var width: CGFloat {
        switch self {
        case .esc: return 44
        case .shot: return 38
        case .brightness: return 74
        case .volume: return 76
        case .battery: return 80
        case .clock: return 50
        case .weather: return 72
        case .input: return 62
        }
    }

    var title: String {
        switch self {
        case .esc: return "esc"
        case .shot: return L.t("Скріншот", "Screenshot")
        case .brightness: return L.t("Яскравість − / +", "Brightness − / +")
        case .volume: return L.t("Гучність − / +", "Volume − / +")
        case .battery: return L.t("Батарея (тап — енергозбереження)", "Battery (tap: Low Power Mode)")
        case .clock: return L.t("Час (тап — Календар)", "Time (tap: Calendar)")
        case .weather: return L.t("Погода (тап — прогноз)", "Weather (tap: forecast)")
        case .input: return L.t("Мова (тап — перемкнути)", "Language (tap: switch)")
        }
    }
}

enum BarLayout {
    static let changed = Notification.Name("ua.vyshyvka.bar.layoutChanged")
    static let defaultLeft: [Slot] = [.esc, .shot, .brightness, .volume]
    static let defaultRight: [Slot] = [.battery, .clock, .weather, .input]

    /// Слоти, доступні на цьому Mac (esc — лише там, де Esc на Touch Bar).
    static var available: [Slot] { Slot.allCases.filter { !($0 == .esc && VB.hasPhysicalEsc) } }

    private static func load(_ k: String, _ def: [Slot]) -> [Slot] {
        guard let a = UserDefaults.standard.stringArray(forKey: k) else { return def }
        return a.compactMap(Slot.init(rawValue:))
    }

    static var left: [Slot] {
        get { normalized().0 }
    }
    static var right: [Slot] {
        get { normalized().1 }
    }
    static var hidden: Set<Slot> {
        get { Set((UserDefaults.standard.stringArray(forKey: "layoutHidden") ?? []).compactMap(Slot.init(rawValue:))) }
    }

    /// Кожен доступний слот рівно в одній групі; нові/втрачені — повертаємо на типове місце.
    static func normalized() -> ([Slot], [Slot]) {
        let av = Set(available)
        var l = load("layoutLeft", defaultLeft).filter { av.contains($0) }
        var r = load("layoutRight", defaultRight).filter { av.contains($0) && !l.contains($0) }
        l = Array(NSOrderedSet(array: l)) as! [Slot]
        r = Array(NSOrderedSet(array: r)) as! [Slot]
        for s in available where !l.contains(s) && !r.contains(s) {
            if defaultLeft.contains(s) { l.append(s) } else { r.append(s) }
        }
        return (l, r)
    }

    static func save(left: [Slot], right: [Slot], hidden: Set<Slot>) {
        let d = UserDefaults.standard
        d.set(left.map(\.rawValue), forKey: "layoutLeft")
        d.set(right.map(\.rawValue), forKey: "layoutRight")
        d.set(hidden.map(\.rawValue), forKey: "layoutHidden")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Сховати вишивку з тризубом (центр панелі лишається чорним).
    static var embroideryHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "hideEmbroidery") }
        set { UserDefaults.standard.set(newValue, forKey: "hideEmbroidery") }
    }

    static func reset() {
        for k in ["layoutLeft", "layoutRight", "layoutHidden", "hideEmbroidery"] { UserDefaults.standard.removeObject(forKey: k) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
