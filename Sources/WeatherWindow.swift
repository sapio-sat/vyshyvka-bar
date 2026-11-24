import AppKit

/// Повне вікно погоди («Детальніше» на Touch Bar або меню ◆): зараз, 24 години, 7 днів.
final class WeatherWindow: NSWindow {
    private let view = WeatherDetailView(frame: NSRect(x: 0, y: 0, width: 920, height: 640))

    init() {
        super.init(contentRect: view.frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = VB.bg
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = view
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ w: Weather?) {
        view.weather = w
        view.needsDisplay = true
        if !isVisible { center() }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: e) } }
}

final class WeatherDetailView: NSView {
    var weather: Weather?
    override var isFlipped: Bool { true }

    private let faint = VB.label.withAlphaComponent(0.55)
    private let rain = NSColor(hex: 0x7FB2F0)

    private func draw(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular, _ c: NSColor, at p: CGPoint, align: NSTextAlignment = .left, mono: Bool = false) {
        let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: w) : NSFont.systemFont(ofSize: size, weight: w)
        let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
        let sz = a.size()
        let x = align == .center ? p.x - sz.width / 2 : align == .right ? p.x - sz.width : p.x
        a.draw(at: CGPoint(x: x, y: p.y))
    }

    /// Іконка з Icons.Glyph у будь-якому масштабі (контури — y-вгору, тому дзеркалимо).
    private func glyph(_ g: Icons.Glyph, center: CGPoint, scale k: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x - g.size.width * k / 2, y: center.y + g.size.height * k / 2)
        ctx.scaleBy(x: k, y: -k)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        func fill(_ p: CGPath, _ c: NSColor) { ctx.addPath(p); ctx.setFillColor(c.cgColor); ctx.fillPath() }
        func stroke(_ p: CGPath, _ c: NSColor, _ w: CGFloat) { ctx.addPath(p); ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); ctx.strokePath() }
        fill(g.fillAccent, VB.red); fill(g.fillInk, VB.ivory)
        stroke(g.ink, VB.ivory, VB.stroke); stroke(g.accent, VB.red, VB.stroke)
        ctx.restoreGState()
    }

    private func stitchRow(y: CGFloat, from x0: CGFloat, to x1: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineCap(.round); ctx.setLineWidth(1.2)
        var x = x0, i = 0
        while x <= x1 {
            ctx.setStrokeColor((i % 4 == 3 ? VB.cream : VB.red).withAlphaComponent(0.75).cgColor)
            ctx.move(to: CGPoint(x: x - 2.5, y: y - 2.5)); ctx.addLine(to: CGPoint(x: x + 2.5, y: y + 2.5))
            ctx.move(to: CGPoint(x: x - 2.5, y: y + 2.5)); ctx.addLine(to: CGPoint(x: x + 2.5, y: y - 2.5))
            ctx.strokePath(); x += 12; i += 1
        }
    }

    override func draw(_ dirty: NSRect) {
        VB.bg.setFill(); bounds.fill()
        let W = bounds.width, pad: CGFloat = 40
        guard let w = weather else {
            draw(L.t("Немає даних про погоду — перевірте з’єднання з інтернетом.", "No weather data — check your internet connection."),
                 15, .regular, faint, at: CGPoint(x: W / 2, y: 300), align: .center)
            return
        }
        // ── Зараз
        draw(City.current.name, 30, .semibold, VB.ivory, at: CGPoint(x: pad, y: 44))
        draw(WeatherText.describe(w.code), 15, .regular, VB.cream, at: CGPoint(x: pad, y: 86))
        glyph(Icons.weather(code: w.code, isDay: w.isDay), center: CGPoint(x: W - 300, y: 82), scale: 4)
        draw(WeatherText.temp(w.celsius), 58, .light, VB.ivory, at: CGPoint(x: W - pad, y: 44), align: .right, mono: true)
        let today = w.days.first
        var facts = [L.t("Відчувається як ", "Feels like ") + WeatherText.temp(w.feels),
                     L.t("Вологість ", "Humidity ") + "\(w.humidity)%",
                     L.t("Вітер ", "Wind ") + String(format: "%.0f ", w.wind) + L.t("м/с", "m/s")]
        if let t = today { facts += [L.t("Схід ", "Sunrise ") + t.sunrise, L.t("Захід ", "Sunset ") + t.sunset] }
        draw(facts.joined(separator: "   ·   "), 13, .regular, faint, at: CGPoint(x: pad, y: 122))
        stitchRow(y: 160, from: pad, to: W - pad)

        // ── 24 години
        draw(L.t("Наступні 24 години", "Next 24 hours"), 13, .semibold, VB.label, at: CGPoint(x: pad, y: 178))
        let hours = Array(w.hours.prefix(24))
        if !hours.isEmpty {
            let cw = (W - 2 * pad) / CGFloat(hours.count)
            for (i, h) in hours.enumerated() {
                let cx = pad + cw * (CGFloat(i) + 0.5)
                draw(i == 0 ? L.t("Зараз", "Now") : h.hour, 11, i == 0 ? .semibold : .regular, i == 0 ? VB.ivory : VB.cream, at: CGPoint(x: cx, y: 204), align: .center)
                glyph(Icons.weather(code: h.code, isDay: h.isDay), center: CGPoint(x: cx, y: 236), scale: 1.15)
                draw(WeatherText.temp(h.celsius), 12, .medium, VB.ivory, at: CGPoint(x: cx, y: 254), align: .center, mono: true)
                if h.precip >= 20 { draw("\(h.precip)%", 10, .regular, rain, at: CGPoint(x: cx, y: 272), align: .center) }
            }
        }
        stitchRow(y: 302, from: pad, to: W - pad)

        // ── 7 днів
        draw(L.t("Прогноз на 7 днів", "7-day forecast"), 13, .semibold, VB.label, at: CGPoint(x: pad, y: 320))
        let days = Array(w.days.prefix(7))
        let lo = days.map(\.min).min() ?? 0, hi = days.map(\.max).max() ?? 1
        let span = CGFloat(max(1, hi - lo))
        let barX0: CGFloat = 560, barX1: CGFloat = W - pad - 50
        for (i, d) in days.enumerated() {
            let y = 352 + CGFloat(i) * 38
            draw(WeatherText.weekday(d.date, short: false), 14, i == 0 ? .semibold : .regular, i == 0 ? VB.ivory : VB.label, at: CGPoint(x: pad, y: y))
            draw(WeatherText.date(d.date), 11.5, .regular, faint, at: CGPoint(x: pad + 112, y: y + 2))
            glyph(Icons.weather(code: d.code, isDay: true), center: CGPoint(x: 226, y: y + 9), scale: 1.3)
            draw(WeatherText.describe(d.code), 12.5, .regular, VB.cream, at: CGPoint(x: 254, y: y + 1))
            if d.precip >= 20 { draw("\(d.precip)%", 12, .regular, rain, at: CGPoint(x: 410, y: y + 1)) }
            draw(String(format: "%.0f ", d.wind) + L.t("м/с", "m/s") + (d.uv >= 3 ? String(format: " · UV %.0f", d.uv) : ""), 11.5, .regular, faint,
                 at: CGPoint(x: 470, y: y + 2))
            // діапазон температур: смужка від мін до макс на спільній шкалі тижня
            draw(WeatherText.temp(d.min), 13, .regular, faint, at: CGPoint(x: barX0 - 8, y: y), align: .right, mono: true)
            draw(WeatherText.temp(d.max), 13, .medium, VB.ivory, at: CGPoint(x: barX1 + 8, y: y), mono: true)
            let track = NSBezierPath(roundedRect: NSRect(x: barX0, y: y + 7, width: barX1 - barX0, height: 4), xRadius: 2, yRadius: 2)
            VB.ivory.withAlphaComponent(0.08).setFill(); track.fill()
            let a = barX0 + (barX1 - barX0) * CGFloat(d.min - lo) / span, b = barX0 + (barX1 - barX0) * CGFloat(d.max - lo) / span
            let seg = NSBezierPath(roundedRect: NSRect(x: a, y: y + 7, width: max(4, b - a), height: 4), xRadius: 2, yRadius: 2)
            NSGradient(colors: [NSColor(hex: 0x6E9EFF), NSColor(hex: 0xFFD64E), NSColor(hex: 0xFF5A60)])!.draw(in: seg, angle: 0)
        }

        let f = DateFormatter(); f.dateFormat = "HH:mm"
        draw(L.t("Дані: Open-Meteo.com · оновлено о ", "Data: Open-Meteo.com · updated at ") + f.string(from: w.updated) + L.t("   ·   Esc — закрити", "   ·   Esc to close"),
             11, .regular, faint, at: CGPoint(x: W / 2, y: 612), align: .center)
    }
}
