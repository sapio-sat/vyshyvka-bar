import AppKit
import QuartzCore

/// Прогноз по днях прямо на Touch Bar (тап по погоді). Розкладка рахується від фактичної ширини смуги,
/// тож однаково вміщується і на 1085 pt (Esc на Touch Bar), і на 1004 pt (фізична Esc).
extension BarView {
    private var faint: NSColor { VB.label.withAlphaComponent(0.55) }
    private static let rainBlue = NSColor(hex: 0x7FB2F0)

    func showForecast() {
        guard !showingForecast else { return }
        setForecast(true)
    }

    func hideForecast() {
        guard showingForecast else { return }
        setForecast(false)
    }

    private func setForecast(_ on: Bool) {
        setShowingForecast(on)
        if on { buildForecast(); embroidery?.stop() } else if animating { embroidery?.start(fps: Self.fps) }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
        applyForecastVisibility()
        CATransaction.commit()
        scheduleForecastTimeout(on)
    }

    func applyForecastVisibility() {
        let on = showingForecast
        forecastLayerRef.opacity = on ? 1 : 0
        for l in [controlsLayerRef, widgetsLayerRef, embroidery?.root].compactMap({ $0 }) { l.opacity = on ? 0 : 1 }
    }

    func buildForecast() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let fl = forecastLayerRef
        fl.sublayers = nil
        let W = visibleWidth, H = VB.barHeight
        var hits: [Control: CGRect] = [.back: CGRect(x: 0, y: 0, width: W, height: H)]

        // ‹ назад
        let chev = CAShapeLayer()
        let cp = CGMutablePath(); cp.move(to: CGPoint(x: 19, y: 21)); cp.addLine(to: CGPoint(x: 13, y: 15)); cp.addLine(to: CGPoint(x: 19, y: 9))
        chev.path = cp; chev.strokeColor = VB.ivory.cgColor; chev.fillColor = nil; chev.lineWidth = 1.6
        chev.lineCap = .round; chev.lineJoin = .round; chev.contentsScale = 2
        fl.addSublayer(chev)

        guard let w = weather, !w.days.isEmpty else {
            let (t, s) = text(L.t("Прогноз недоступний — немає з’єднання", "Forecast unavailable — no connection"), size: 12.5, color: faint)
            place(t, s, x: (W - s.width) / 2, in: fl)
            forecastHit = hits
            CATransaction.commit(); return
        }

        // Зараз: іконка + велика температура + місто / «відчув.»
        var x: CGFloat = 38
        let g = Icons.weather(code: w.code, isDay: w.isDay)
        fl.addSublayer(glyphLayer(g, at: CGPoint(x: x, y: (H - g.size.height) / 2))); x += g.size.width + 6
        let (tt, ts) = text(WeatherText.temp(w.celsius), size: 16, color: VB.ivory)
        place(tt, ts, x: x, in: fl); x += ts.width + 8
        let (c1, s1) = text(City.current.name, size: 10.5, color: VB.cream)
        let (c2, s2) = text(L.t("відч. ", "feels ") + WeatherText.temp(w.feels) + String(format: " · %.0f ", w.wind) + L.t("м/с", "m/s"),
                            size: 10, color: faint)
        c1.frame = CGRect(x: x, y: 15.5, width: s1.width, height: s1.height); fl.addSublayer(c1)
        c2.frame = CGRect(x: x, y: 2.5, width: s2.width, height: s2.height); fl.addSublayer(c2)
        x += max(s1.width, s2.width) + 10

        // «Детальніше ›» — праворуч
        let (dt, ds) = text(L.t("Детальніше", "Details"), size: 12.5, color: VB.ivory)
        let bw = ds.width + 30, bx = W - bw - 8
        let pill = CAShapeLayer()
        pill.path = CGPath(roundedRect: CGRect(x: bx, y: 4, width: bw, height: H - 8), cornerWidth: 11, cornerHeight: 11, transform: nil)
        pill.fillColor = VB.ivory.withAlphaComponent(0.09).cgColor
        pill.strokeColor = VB.cream.withAlphaComponent(0.35).cgColor; pill.lineWidth = 0.8; pill.contentsScale = 2
        fl.addSublayer(pill)
        place(dt, ds, x: bx + 11, in: fl)
        let arrow = CAShapeLayer()
        let ap = CGMutablePath(); ap.move(to: CGPoint(x: bx + bw - 14, y: 18.5)); ap.addLine(to: CGPoint(x: bx + bw - 10.5, y: 15)); ap.addLine(to: CGPoint(x: bx + bw - 14, y: 11.5))
        arrow.path = ap; arrow.strokeColor = VB.red.cgColor; arrow.fillColor = nil; arrow.lineWidth = 1.4; arrow.lineCap = .round; arrow.contentsScale = 2
        fl.addSublayer(arrow)
        hits[.details] = CGRect(x: bx - 6, y: 0, width: bw + 14, height: H)

        // Дні: рівні комірки між «зараз» і кнопкою
        let days = Array(w.days.prefix(7))
        let x0 = x + 4, x1 = bx - 10
        let cw = (x1 - x0) / CGFloat(days.count)
        for (i, d) in days.enumerated() {
            let cx = x0 + cw * CGFloat(i)
            let (dn, dns) = text(WeatherText.weekday(d.date), size: 10.5, color: i == 0 ? VB.ivory : VB.cream)
            let pr = d.precip >= 20 ? text("\(d.precip)%", size: 9.5, color: Self.rainBlue) : nil
            let ic = Icons.weather(code: d.code, isDay: true)
            let (mx, mxs) = text(WeatherText.temp(d.max), size: 12.5, color: VB.ivory)
            let (mn, mns) = text(WeatherText.temp(d.min), size: 10.5, color: faint)
            let col1 = max(dns.width, pr?.1.width ?? 0), col2 = max(mxs.width, mns.width)
            let total = col1 + 5 + ic.size.width + 5 + col2
            var px = cx + (cw - total) / 2
            dn.frame = CGRect(x: px + (col1 - dns.width) / 2, y: pr == nil ? (H - dns.height) / 2 + 0.5 : 15.5, width: dns.width, height: dns.height)
            fl.addSublayer(dn)
            if let (pt, ps) = pr { pt.frame = CGRect(x: px + (col1 - ps.width) / 2, y: 3, width: ps.width, height: ps.height); fl.addSublayer(pt) }
            px += col1 + 5
            fl.addSublayer(glyphLayer(ic, at: CGPoint(x: px, y: (H - ic.size.height) / 2))); px += ic.size.width + 5
            mx.frame = CGRect(x: px, y: 14.5, width: mxs.width, height: mxs.height); fl.addSublayer(mx)
            mn.frame = CGRect(x: px, y: 2.5, width: mns.width, height: mns.height); fl.addSublayer(mn)
            if i > 0 {   // роздільник — вишитий хрестик
                let st = CAShapeLayer(); let sp = CGMutablePath(), a: CGFloat = 1.8, sx = cx, sy = H / 2
                sp.move(to: CGPoint(x: sx - a, y: sy - a)); sp.addLine(to: CGPoint(x: sx + a, y: sy + a))
                sp.move(to: CGPoint(x: sx - a, y: sy + a)); sp.addLine(to: CGPoint(x: sx + a, y: sy - a))
                st.path = sp; st.strokeColor = VB.red.withAlphaComponent(0.7).cgColor; st.lineWidth = 0.9; st.lineCap = .round; st.contentsScale = 2
                fl.addSublayer(st)
            }
        }
        forecastHit = hits
        CATransaction.commit()
    }

    private func scheduleForecastTimeout(_ on: Bool) {
        cancelForecastTimeout()
        guard on else { return }
        let job = DispatchWorkItem { [weak self] in self?.hideForecast() }
        storeForecastTimeout(job)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: job)
    }
}
