import AppKit
import QuartzCore

/// V5: одна непрерывная чёрная поверхность. Без рамки, разделителей и плиток —
/// только живая вышивка, иконки, подписи и невидимые зоны касания.
final class BarView: NSView {
    enum Control: CaseIterable { case esc, shot, brightnessDown, brightnessUp, volumeDown, volumeUp, input, trident, weather, back, details, clock, battery }

    var battery = BatteryState(percent: -1, charging: false, onAC: true) { didSet { if battery != oldValue { rebuildWidgets() } } }
    var time = "--:--" { didSet { if time != oldValue { rebuildWidgets() } } }
    var weather: Weather? { didSet { weatherKnown = true; rebuildWidgets(); if showingForecast { buildForecast() } } }
    var input = "—" { didSet { if input != oldValue { rebuildWidgets() } } }
    var accessibilityTrusted = true { didSet { if accessibilityTrusted != oldValue { buildControls() } } }
    private var weatherKnown = false

    var onAction: ((Control) -> Void)?

    private let root = CALayer()
    private let controlsLayer = CALayer()
    private let widgetsLayer = CALayer()
    private let forecastLayer = CALayer()
    private(set) var showingForecast = false
    var forecastHit: [Control: CGRect] = [:]
    private var forecastTimeout: DispatchWorkItem?
    private let pressGlow = CAGradientLayer()
    private let levelTrack = CAShapeLayer()
    private let levelFill = CAShapeLayer()
    private(set) var embroidery: Embroidery!

    private var hit: [Control: CGRect] = [:]
    private var widgetSlots: [Slot: (CGFloat, CGFloat)] = [:]
    private var lastWidth: CGFloat = 0
    private var touches: [NSObject: Control] = [:]
    private var repeatTimer: Timer?
    private var levelHide: DispatchWorkItem?

    /// Частота анимации: по умолчанию 24 fps (баланс плавности и нагрузки TouchBarServer).
    /// defaults write ua.vyshyvka.bar fps -int 30   (допустимо 15…60)
    static var fps: Int {
        let v = UserDefaults.standard.integer(forKey: "fps")
        return v == 0 ? 24 : min(60, max(15, v))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        allowedTouchTypes = [.direct]
        root.backgroundColor = VB.bg.cgColor
        root.contentsScale = 2

        pressGlow.type = .radial
        pressGlow.colors = [VB.cream.withAlphaComponent(0.2).cgColor, VB.cream.withAlphaComponent(0.06).cgColor,
                            VB.cream.withAlphaComponent(0).cgColor]
        pressGlow.locations = [0, 0.5, 1]
        pressGlow.startPoint = CGPoint(x: 0.5, y: 0.5); pressGlow.endPoint = CGPoint(x: 1, y: 1)
        pressGlow.opacity = 0

        for l in [levelTrack, levelFill] { l.lineWidth = 1; l.lineCap = .round; l.contentsScale = 2; l.opacity = 0 }
        levelTrack.strokeColor = VB.ivory.withAlphaComponent(0.2).cgColor
        levelFill.strokeColor = VB.ivory.cgColor
        [controlsLayer, widgetsLayer].forEach { $0.contentsScale = 2 }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: VB.barWidth, height: VB.barHeight) }

    override func layout() {
        super.layout()
        if visibleWidth != lastWidth { relayout() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// Фактично видима ширина: не більше, ніж вікно Touch Bar показує праворуч від початку панелі
    /// (страховка для моделей, де смуга коротша за запитану ширину).
    var visibleWidth: CGFloat {
        var w = bounds.width
        if let cv = window?.contentView, cv.bounds.width > 300 {
            let x = convert(NSPoint.zero, to: nil).x
            w = min(w, cv.bounds.width - x)
        }
        return max(w, 300)
    }

    // MARK: - Раскладка

    /// Розставляє слот у прямокутнику: кнопки керування — у hit, віджети — ще й у widgetSlots.
    private func placeSlot(_ s: Slot, x: CGFloat, H: CGFloat) {
        let w = s.width
        switch s {
        case .esc: hit[.esc] = CGRect(x: x, y: 0, width: w, height: H)
        case .shot: hit[.shot] = CGRect(x: x, y: 0, width: w, height: H)
        case .brightness:
            hit[.brightnessDown] = CGRect(x: x, y: 0, width: 36, height: H); hit[.brightnessUp] = CGRect(x: x + 36, y: 0, width: 38, height: H)
        case .volume:
            hit[.volumeDown] = CGRect(x: x, y: 0, width: 36, height: H); hit[.volumeUp] = CGRect(x: x + 36, y: 0, width: 40, height: H)
        case .battery: widgetSlots[s] = (x, w); hit[.battery] = CGRect(x: x, y: 0, width: w, height: H)
        case .clock: widgetSlots[s] = (x, w); hit[.clock] = CGRect(x: x, y: 0, width: w, height: H)
        case .weather: widgetSlots[s] = (x, w); hit[.weather] = CGRect(x: x, y: 0, width: w, height: H)
        case .input: widgetSlots[s] = (x, w); hit[.input] = CGRect(x: x, y: 0, width: w + 6, height: H)
        }
    }

    func relayout() {
        lastWidth = visibleWidth
        let W = lastWidth, H = bounds.height
        if window != nil {
            hwLog.notice("bar layout: model=\(VB.model, privacy: .public) bounds=\(Int(self.bounds.width)) window=\(Int(self.window?.contentView?.bounds.width ?? 0)) used=\(Int(W)) physicalEsc=\(VB.hasPhysicalEsc)")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = bounds
        root.sublayers = nil

        // Порядок і видимість — з налаштувань (BarLayout); ліва група від лівого краю, права — від правого.
        var x: CGFloat = 8
        hit = [:]
        widgetSlots = [:]
        let hidden = BarLayout.hidden
        for s in BarLayout.left where !hidden.contains(s) { placeSlot(s, x: x, H: H); x += s.width }
        let leftEnd = x
        var r = W - 6
        for s in BarLayout.right.reversed() where !hidden.contains(s) { r -= s.width; placeSlot(s, x: r, H: H) }
        let rightStart = r

        let center = W / 2
        if !BarLayout.embroideryHidden { hit[.trident] = CGRect(x: center - 22, y: 0, width: 44, height: H) }   // тап по гербу → зведення
        let halfW = max(40, min(center - (leftEnd + 8), (rightStart - 8) - center))
        embroidery = Embroidery(centerX: center, halfWidth: halfW, height: H)
        embroidery.root.frame = bounds
        embroidery.root.isHidden = BarLayout.embroideryHidden
        [embroidery.root, pressGlow, controlsLayer, widgetsLayer, forecastLayer, levelTrack, levelFill].forEach(root.addSublayer)
        forecastLayer.frame = bounds
        if showingForecast { buildForecast(); applyForecastVisibility() }
        embroidery.apply(time: 0)
        buildControls()
        rebuildWidgets()
        CATransaction.commit()
        if animating { startMotion() }
    }

    // MARK: - Иконки и подписи

    static let lowPowerYellow = NSColor(hex: 0xF2C14E)

    func glyphLayer(_ g: Icons.Glyph, at o: CGPoint, accent: NSColor = VB.red) -> CALayer {
        let box = CALayer()
        box.frame = CGRect(origin: o, size: g.size)
        func add(_ p: CGPath, stroke: NSColor?, fill: NSColor?, width: CGFloat = VB.stroke) {
            let s = CAShapeLayer(); s.path = p
            s.strokeColor = stroke?.cgColor; s.fillColor = fill?.cgColor
            s.lineWidth = width; s.lineCap = .round; s.lineJoin = .round; s.contentsScale = 2
            box.addSublayer(s)
        }
        add(g.fillAccent, stroke: nil, fill: accent)
        add(g.fillInk, stroke: nil, fill: VB.ivory)
        add(g.halo, stroke: VB.bg, fill: nil, width: 2.8)
        add(g.ink, stroke: VB.ivory, fill: nil)
        add(g.accent, stroke: accent, fill: nil)
        add(g.shine, stroke: VB.ivory.withAlphaComponent(0.5), fill: nil, width: 0.7)
        return box
    }

    func text(_ s: String, size: CGFloat = 13.5, color: NSColor = VB.label) -> (CATextLayer, CGSize) {
        let a = NSAttributedString(string: s, attributes: [.font: VB.font(size, .medium), .foregroundColor: color, .kern: 0.2])
        let sz = a.size()
        let t = CATextLayer(); t.string = a; t.contentsScale = 2; t.isWrapped = false
        return (t, CGSize(width: ceil(sz.width) + 1, height: ceil(sz.height)))
    }

    func place(_ t: CATextLayer, _ size: CGSize, x: CGFloat, in parent: CALayer) {
        t.frame = CGRect(x: x, y: (VB.barHeight - size.height) / 2 + 0.5, width: size.width, height: size.height)
        parent.addSublayer(t)
    }

    private func buildControls() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        controlsLayer.sublayers = nil
        let H = VB.barHeight
        for c in [Control.esc, .shot, .brightnessDown, .brightnessUp, .volumeDown, .volumeUp] {
            guard let r = hit[c] else { continue }
            var layer: CALayer
            switch c {
            case .esc:
                let (t, s) = text("esc", size: 14)
                t.frame = CGRect(x: r.midX - s.width / 2, y: (H - s.height) / 2 + 0.5, width: s.width, height: s.height)
                layer = t
            case .shot: let g = Icons.viewfinder(); layer = glyphLayer(g, at: CGPoint(x: r.midX - g.size.width / 2, y: (H - g.size.height) / 2))
            case .brightnessDown, .brightnessUp:
                let g = Icons.sun(strong: c == .brightnessUp); layer = glyphLayer(g, at: CGPoint(x: r.midX - g.size.width / 2, y: (H - g.size.height) / 2))
            case .volumeDown, .volumeUp:
                let g = Icons.speaker(strong: c == .volumeUp); layer = glyphLayer(g, at: CGPoint(x: r.midX - g.size.width / 2, y: (H - g.size.height) / 2))
            case .input, .trident, .weather, .back, .details, .clock, .battery: continue
            }
            // Без Accessibility esc и скриншот не дойдут до системы — честно приглушаем
            if (c == .esc || c == .shot) && !accessibilityTrusted { layer.opacity = 0.38 }
            controlsLayer.addSublayer(layer)
        }
        CATransaction.commit()
    }

    private func rebuildWidgets() {

        CATransaction.begin(); CATransaction.setDisableActions(true)
        widgetsLayer.sublayers = nil
        let H = VB.barHeight
        func group(_ slot: (CGFloat, CGFloat)?, icon: Icons.Glyph?, accent: NSColor = VB.red, label: String, color: NSColor = VB.label, trailing: Icons.Glyph? = nil) {
            guard let slot = slot else { return }
            let (t, s) = text(label, color: color)
            let gap: CGFloat = icon == nil ? 0 : 5
            let tw = trailing.map { $0.size.width + 3.5 } ?? 0
            let total = (icon?.size.width ?? 0) + gap + s.width + tw
            var x = slot.0 + (slot.1 - total) / 2
            if let g = icon { widgetsLayer.addSublayer(glyphLayer(g, at: CGPoint(x: x, y: (H - g.size.height) / 2), accent: accent)); x += g.size.width + gap }
            place(t, s, x: x, in: widgetsLayer)
            if let g = trailing {
                let l = glyphLayer(g, at: CGPoint(x: x + s.width + 2.5, y: (H - g.size.height) / 2 - 0.5)); l.opacity = 0.6
                widgetsLayer.addSublayer(l)
            }
        }
        let b = battery
        group(widgetSlots[.battery], icon: Icons.battery(percent: b.percent, charging: b.charging), accent: b.lowPower ? Self.lowPowerYellow : (b.percent >= 0 && b.percent <= 10 && !b.onAC ? VB.red : VB.ivory),
              label: b.percent < 0 ? "—" : "\(b.percent)%",
              color: (b.percent >= 0 && b.percent <= 10 && !b.onAC) ? NSColor(hex: 0xE3707A) : VB.label)
        group(widgetSlots[.clock], icon: nil, label: time)
        if let w = weather {
            group(widgetSlots[.weather], icon: Icons.weather(code: w.code, isDay: w.isDay), label: (w.celsius > 0 ? "+" : "") + "\(w.celsius)°")
        } else {
            group(widgetSlots[.weather], icon: Icons.weather(code: nil, isDay: true), label: weatherKnown ? L.t("н/д", "n/a") : "…",
                  color: VB.label.withAlphaComponent(0.55))
        }
        group(widgetSlots[.input], icon: nil, label: input)          // без стрілки: тап просто перемикає мову
        CATransaction.commit()
    }

    // Доступ для розширення Forecast.swift
    var forecastLayerRef: CALayer { forecastLayer }
    var controlsLayerRef: CALayer { controlsLayer }
    var widgetsLayerRef: CALayer { widgetsLayer }
    func setShowingForecast(_ on: Bool) { showingForecast = on }
    func storeForecastTimeout(_ j: DispatchWorkItem) { forecastTimeout = j }
    func cancelForecastTimeout() { forecastTimeout?.cancel(); forecastTimeout = nil }
    var forecastHitStore: [Control: CGRect] { get { forecastHit } set { forecastHit = newValue } }

    // MARK: - Движение

    private(set) var animating = false
    func startMotion() { animating = true; if !showingForecast { embroidery?.start(fps: Self.fps) } }
    func stopMotion(staticTime: Double = 6.0) { animating = false; embroidery?.stop(); embroidery?.apply(time: staticTime) }

    /// Индикатор уровня под иконкой — значение, прочитанное из системы после шага.
    func showLevel(_ value: Float?, for c: Control) {
        guard let v = value, let r = hit[c] else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y: CGFloat = 3.2, w: CGFloat = 20, x0 = r.midX - w / 2
        let tp = CGMutablePath(); tp.move(to: CGPoint(x: x0, y: y)); tp.addLine(to: CGPoint(x: x0 + w, y: y))
        let fp = CGMutablePath(); fp.move(to: CGPoint(x: x0, y: y)); fp.addLine(to: CGPoint(x: x0 + max(0.5, w * CGFloat(v)), y: y))
        levelTrack.path = tp; levelFill.path = fp
        levelTrack.opacity = 1; levelFill.opacity = 1
        CATransaction.commit()
        levelHide?.cancel()
        let job = DispatchWorkItem { [weak self] in
            CATransaction.begin(); CATransaction.setAnimationDuration(0.5)
            self?.levelTrack.opacity = 0; self?.levelFill.opacity = 0
            CATransaction.commit()
        }
        levelHide = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: job)
    }

    // MARK: - Касания

    func control(at p: CGPoint) -> Control? {
        if showingForecast { return forecastHit[.details]?.contains(p) == true ? .details : .back }   // будь-який дотик — назад
        return hit.first { $0.value.contains(p) }?.key
    }

    private func highlight(_ c: Control?, on: Bool) {
        if showingForecast && c == .back { return }                  // «назад» — уся смуга, без підсвітки
        guard let c = c, let r = (showingForecast ? forecastHit[c] : hit[c]) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pressGlow.frame = CGRect(x: r.midX - 24, y: r.midY - 20, width: 48, height: 40)
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = pressGlow.presentation()?.opacity ?? pressGlow.opacity
        a.toValue = on ? 1 : 0
        a.duration = on ? 0.06 : 0.3
        pressGlow.opacity = on ? 1 : 0
        pressGlow.add(a, forKey: "opacity")
    }

    private func isRepeating(_ c: Control) -> Bool { [.brightnessDown, .brightnessUp, .volumeDown, .volumeUp].contains(c) }

    override func touchesBegan(with event: NSEvent) {
        for t in event.touches(matching: .began, in: self) {
            guard let c = control(at: t.location(in: self)) else { continue }
            touches[t.identity as! NSObject] = c
            highlight(c, on: true)
            if isRepeating(c) {
                onAction?(c)
                repeatTimer?.invalidate()
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.onAction?(c) }
                }
            }
        }
    }

    override func touchesEnded(with event: NSEvent) {
        for t in event.touches(matching: .ended, in: self) {
            guard let c = touches.removeValue(forKey: t.identity as! NSObject) else { continue }
            highlight(c, on: false)
            repeatTimer?.invalidate(); repeatTimer = nil
            if !isRepeating(c), (showingForecast ? forecastHit[c] : hit[c])?.insetBy(dx: -8, dy: -8).contains(t.location(in: self)) == true { onAction?(c) }
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        for t in event.touches(matching: .cancelled, in: self) {
            if let c = touches.removeValue(forKey: t.identity as! NSObject) { highlight(c, on: false) }
        }
        repeatTimer?.invalidate(); repeatTimer = nil
    }

    // MARK: - Нативный предпросмотр: тот же слой, модельные значения на момент t

    func snapshot(time: Double, scale: CGFloat = 2) -> CGImage {
        embroidery.apply(time: time)
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        return ctx.makeImage()!
    }
}
