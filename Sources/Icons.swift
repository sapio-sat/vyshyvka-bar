import AppKit

// Иконки V5: тонкие льняные контуры, вариант «+» отличается заливкой/силой, а не знаком.
// Пути y-вверх; рисуются CAShapeLayer (всегда резкие на 2x).

enum Icons {
    struct Glyph {
        var ink = CGMutablePath()          // контур льняной
        var fillInk = CGMutablePath()      // заливка льняная
        var accent = CGMutablePath()       // контур красный
        var fillAccent = CGMutablePath()   // заливка красная
        var shine = CGMutablePath()        // светлый блик
        var halo = CGMutablePath()         // тёмная обводка под контуром (молния поверх заливки)
        var size: CGSize
    }

    /// Видоискатель: четыре открытых уголка + микро-стежки на концах и ромбик в центре.
    static func viewfinder() -> Glyph {
        var g = Glyph(size: CGSize(width: 17, height: 14))
        let w: CGFloat = 17, h: CGFloat = 14, l: CGFloat = 4.2
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: h - l), CGPoint(x: 0, y: h), CGPoint(x: l, y: h)),
            (CGPoint(x: w - l, y: h), CGPoint(x: w, y: h), CGPoint(x: w, y: h - l)),
            (CGPoint(x: w, y: l), CGPoint(x: w, y: 0), CGPoint(x: w - l, y: 0)),
            (CGPoint(x: l, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: l)),
        ]
        for (a, b, c) in corners {
            g.ink.move(to: a); g.ink.addLine(to: b); g.ink.addLine(to: c)
            for e in [a, c] {   // микро-стежок: точка-узелок на конце нити
                g.fillAccent.addEllipse(in: CGRect(x: e.x - 0.55, y: e.y - 0.55, width: 1.1, height: 1.1))
            }
        }
        let m = CGPoint(x: w / 2, y: h / 2), r: CGFloat = 1.7
        g.fillAccent.move(to: CGPoint(x: m.x, y: m.y + r)); g.fillAccent.addLine(to: CGPoint(x: m.x + r, y: m.y))
        g.fillAccent.addLine(to: CGPoint(x: m.x, y: m.y - r)); g.fillAccent.addLine(to: CGPoint(x: m.x - r, y: m.y)); g.fillAccent.closeSubpath()
        return g
    }

    static func sun(strong: Bool) -> Glyph {
        var g = Glyph(size: CGSize(width: 16, height: 16))
        let c = CGPoint(x: 8, y: 8)
        let r: CGFloat = strong ? 3.1 : 2.6
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        if strong { g.fillInk.addEllipse(in: disc) } else { g.ink.addEllipse(in: disc) }
        let (r0, r1): (CGFloat, CGFloat) = strong ? (5.0, 7.6) : (4.6, 6.4)
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4
            g.ink.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
            g.ink.addLine(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
        }
        return g
    }

    static func speaker(strong: Bool) -> Glyph {
        var g = Glyph(size: CGSize(width: 18, height: 14))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 0.6, y: 4.8)); body.addLine(to: CGPoint(x: 3.6, y: 4.8))
        body.addLine(to: CGPoint(x: 7.6, y: 1.3)); body.addLine(to: CGPoint(x: 7.6, y: 12.7))
        body.addLine(to: CGPoint(x: 3.6, y: 9.2)); body.addLine(to: CGPoint(x: 0.6, y: 9.2)); body.closeSubpath()
        if strong { g.fillInk.addPath(body) } else { g.ink.addPath(body) }
        let c = CGPoint(x: 8.4, y: 7)
        g.ink.addArc(center: c, radius: 3.2, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
        if strong {
            g.ink.move(to: CGPoint(x: c.x + 6 * cos(-.pi / 3.6), y: c.y + 6 * sin(-.pi / 3.6)))
            g.ink.addArc(center: c, radius: 6, startAngle: -.pi / 3.6, endAngle: .pi / 3.6, clockwise: false)
        }
        return g
    }

    /// Батарея: один цельный «жидкий» участок = точно percent от полезной длины.
    static func battery(percent: Int, charging: Bool) -> Glyph {
        var g = Glyph(size: CGSize(width: 24, height: 11))
        g.ink.addRoundedRect(in: CGRect(x: 0.5, y: 0.5, width: 21, height: 10), cornerWidth: 3, cornerHeight: 3)
        g.ink.move(to: CGPoint(x: 23.2, y: 3.9)); g.ink.addLine(to: CGPoint(x: 23.2, y: 7.1))
        let inner = CGRect(x: 2, y: 2, width: 18, height: 7)
        let p = CGFloat(max(0, min(100, percent))) / 100
        if p > 0 {
            let w = max(1.2, inner.width * p)
            let fill = CGMutablePath()
            let x1 = inner.minX + w
            fill.move(to: CGPoint(x: inner.minX + 1.6, y: inner.minY))
            fill.addLine(to: CGPoint(x: x1 - 0.5, y: inner.minY))
            // мягкий мениск — поверхность жидкости
            fill.addQuadCurve(to: CGPoint(x: x1 - 0.5, y: inner.maxY), control: CGPoint(x: x1 + 0.9, y: inner.midY))
            fill.addLine(to: CGPoint(x: inner.minX + 1.6, y: inner.maxY))
            fill.addQuadCurve(to: CGPoint(x: inner.minX + 1.6, y: inner.minY), control: CGPoint(x: inner.minX - 0.4, y: inner.midY))
            fill.closeSubpath()
            g.fillAccent.addPath(fill)
            // блик по верхнему краю жидкости
            g.shine.move(to: CGPoint(x: inner.minX + 1.8, y: inner.maxY - 1.4))
            g.shine.addLine(to: CGPoint(x: max(inner.minX + 2, x1 - 1.6), y: inner.maxY - 1.4))
        }
        if charging {
            for p in [g.halo, g.ink] {
                p.move(to: CGPoint(x: 12.2, y: 9.6)); p.addLine(to: CGPoint(x: 9.6, y: 5.6))
                p.addLine(to: CGPoint(x: 12.2, y: 5.6)); p.addLine(to: CGPoint(x: 9.8, y: 1.4))
            }
        }
        return g
    }

    static func weather(code: Int?, isDay: Bool) -> Glyph {
        var g = Glyph(size: CGSize(width: 19, height: 13))
        func cloud(_ dx: CGFloat, _ dy: CGFloat) {
            let p = g.ink
            p.move(to: CGPoint(x: dx + 3, y: dy + 1)); p.addLine(to: CGPoint(x: dx + 14, y: dy + 1))
            p.addArc(center: CGPoint(x: dx + 14, y: dy + 4), radius: 3, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            p.addArc(center: CGPoint(x: dx + 9.5, y: dy + 6.2), radius: 4.0, startAngle: .pi * 0.05, endAngle: .pi * 0.95, clockwise: false)
            p.addArc(center: CGPoint(x: dx + 3.5, y: dy + 4.2), radius: 3.2, startAngle: .pi * 0.45, endAngle: .pi * 1.5, clockwise: false)
        }
        func sun(_ c: CGPoint, _ r: CGFloat) {
            if isDay {
                g.accent.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                for k in 0..<8 {
                    let a = CGFloat(k) * .pi / 4
                    g.accent.move(to: CGPoint(x: c.x + (r + 1.3) * cos(a), y: c.y + (r + 1.3) * sin(a)))
                    g.accent.addLine(to: CGPoint(x: c.x + (r + 2.4) * cos(a), y: c.y + (r + 2.4) * sin(a)))
                }
            } else {
                g.accent.addArc(center: c, radius: r + 0.6, startAngle: .pi * 0.35, endAngle: .pi * 1.65, clockwise: false)
            }
        }
        guard let code = code else { cloud(1, 1.5); return g }
        switch code {
        case 0: sun(CGPoint(x: 9.5, y: 6.5), 3.2)
        case 1, 2: sun(CGPoint(x: 6.5, y: 9), 2.4); cloud(2.5, 0.5)
        case 45, 48:
            cloud(1, 4)
            for y: CGFloat in [1.2, 3.0] { g.ink.move(to: CGPoint(x: 2, y: y)); g.ink.addLine(to: CGPoint(x: 16, y: y)) }
        case 51...67, 80...82:
            cloud(1, 4)
            for x: CGFloat in [5, 9, 13] { g.accent.move(to: CGPoint(x: x, y: 2.6)); g.accent.addLine(to: CGPoint(x: x - 1, y: 0.4)) }
        case 71...77, 85, 86:
            cloud(1, 4)
            for x: CGFloat in [5, 9, 13] { g.fillAccent.addEllipse(in: CGRect(x: x - 0.6, y: 0.6, width: 1.2, height: 1.2)) }
        case 95...99:
            cloud(1, 4)
            g.accent.move(to: CGPoint(x: 10, y: 3.4)); g.accent.addLine(to: CGPoint(x: 8.2, y: 1.6))
            g.accent.addLine(to: CGPoint(x: 10, y: 1.6)); g.accent.addLine(to: CGPoint(x: 8.4, y: -0.6))
        default: cloud(1, 1.5)
        }
        return g
    }

    static func chevron() -> Glyph {
        var g = Glyph(size: CGSize(width: 6, height: 4))
        g.ink.move(to: CGPoint(x: 0.5, y: 3.2)); g.ink.addLine(to: CGPoint(x: 3, y: 0.8)); g.ink.addLine(to: CGPoint(x: 5.5, y: 3.2))
        return g
    }
}
