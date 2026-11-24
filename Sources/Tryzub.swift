import AppKit

// Силуэт тризуба без щита. Геометрия правой половины — из публичного достояния
// Wikimedia Commons «Coat_of_Arms_of_Ukraine.svg» (через design/tryzub_vector_starting_point.svg
// пакета V5), левая — зеркальная, как в оригинале. Пропорции не искажаются.

enum Tryzub {
    static let rightHalf = "m329 53c-6 4-2 396 0 401 12 43 29 81 48 112-104 31-63 146-48 287 7-12 17-21 28-28 43-34 70-81 79-132h133v-580c-148 88-132 213-148 361 59-10 75 76-3 83-92-149-59-257-59-419 0-37-9-62-30-85zm200 143v297h-22c-6-23-21-41-42-51 8-85 10-189 64-246zm-22 337h22v120h-89c0-19-3-39-8-58 36-4 68-29 75-62zm-114 71c4 16 6 33 6 49h-50c1-27 19-44 44-49zm-44 89h46c-7 31-23 61-46 85z"
    static let viewBox = CGRect(x: 70, y: 38, width: 520, height: 832)

    /// Путь высотой `height` pt, центр низа — в `base` (y вверх, как у CALayer).
    static func path(height: CGFloat, centerX: CGFloat, baseY: CGFloat) -> CGPath {
        let half = SVGPath.parse(rightHalf)
        var flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 658, ty: 0)
        let mirrored = half.copy(using: &flip)!
        // Половини перекриваються по центральному мечу, а дзеркальна має зворотний напрям обходу:
        // при простому додаванні контурів заливка в перекритті гасилась (меч «розщеплювався»).
        // Об’єднання дає цілісний силует, як в оригінальному SVG (там кожна половина заливається окремо).
        let full: CGPath
        if #available(macOS 13.0, *) {
            full = half.union(mirrored, using: .winding)
        } else {
            let m = CGMutablePath(); m.addPath(half); m.addPath(mirrored); full = m
        }
        let s = height / viewBox.height
        // SVG: y вниз → переворот; центр по x = 329 (ось симметрии)
        var t = CGAffineTransform(translationX: centerX, y: baseY)
            .scaledBy(x: s, y: -s)
            .translatedBy(x: -329, y: -(viewBox.maxY))
        return full.copy(using: &t)!
    }
}

/// Минимальный разбор SVG path data: M m L l H h V v C c S s Q q Z z.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if ch.isLetter && ch != "e" { flush(); tokens.append(String(ch)) }
            else if ch == "-" { if let l = num.last, l == "e" { num.append(ch) } else { flush(); num = "-" } }
            else if ch == "," || ch == " " || ch == "\n" { flush() }
            else if ch == "." && num.contains(".") { flush(); num = "." }
            else { num.append(ch) }
        }
        flush()
        let p = CGMutablePath()
        var i = 0, cmd = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        func isNum() -> Bool { i < tokens.count && Double(tokens[i]) != nil }
        while i < tokens.count {
            if !isNum() { cmd = tokens[i]; i += 1 }
            let rel = cmd == cmd.lowercased()
            let o = rel ? cur : .zero
            switch cmd.uppercased() {
            case "M":
                cur = CGPoint(x: o.x + n(), y: o.y + n()); start = cur; p.move(to: cur)
                cmd = rel ? "l" : "L"; lastCtrl = nil
            case "L": cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addLine(to: cur); lastCtrl = nil
            case "H": cur = CGPoint(x: (rel ? cur.x : 0) + n(), y: cur.y); p.addLine(to: cur); lastCtrl = nil
            case "V": cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + n()); p.addLine(to: cur); lastCtrl = nil
            case "C":
                let c1 = CGPoint(x: o.x + n(), y: o.y + n()), c2 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addCurve(to: cur, control1: c1, control2: c2); lastCtrl = c2
            case "S":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addCurve(to: cur, control1: c1, control2: c2); lastCtrl = c2
            case "Q":
                let c = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addQuadCurve(to: cur, control: c); lastCtrl = nil
            case "Z": p.closeSubpath(); cur = start; lastCtrl = nil
            default: i += 1
            }
        }
        return p
    }
}
