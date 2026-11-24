import AppKit
import QuartzCore

// Живая вышивка V5. Всё — векторные CAShapeLayer, созданные один раз.
// Движение — заранее вычисленные ключевые кадры strokeEnd/transform/opacity/цвета,
// которые ведёт рендер-сервер Core Animation (CPU приложения не участвует).
// Те же функции времени используются для предпросмотра → кадры идентичны.

// MARK: - Движок дорожек

struct Track {
    let layer: CALayer
    let key: String
    let period: Double
    let fn: (Double) -> Any          // абсолютное время, с → значение свойства
    var part = Embroidery.currentPart
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func smoothstep(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func frac(_ x: Double) -> Double { x - floor(x) }

/// Фронт нити 0…1 на фазе u: рост из тризуба → полное плетение → расплетение обратно в тризуб.
/// f(0) = f(1) = 0 с нулевой производной → бесшовный цикл.
struct Weave {
    var grow = 0.40, hold = 0.18           // доли цикла; остальное — возврат
    func front(_ u: Double) -> Double {
        if u < grow { return easeInOut(u / grow) }
        if u < grow + hold { return 1 }
        return 1 - easeInOut((u - grow - hold) / (1 - grow - hold))
    }
}

enum Rainbow {
    static let period = 12.8
    /// Яркостно выровненный спектр: красный → оранжевый → жёлтый → зелёный → голубой → синий → фиолетовый → красный.
    static let stops: [NSColor] = [0xFF5A60, 0xFF9845, 0xFFD64E, 0x82E07C, 0x55D7E6, 0x6E9EFF, 0xB683FF, 0xFF6AA8, 0xFF5A60]
        .map { NSColor(hex: $0) }
    static func color(_ t: Double, alpha: CGFloat = 1, period: Double = Rainbow.period) -> CGColor {
        let x = frac(t / period) * Double(stops.count - 1)
        let i = Int(x), k = CGFloat(x - Double(i))
        let a = stops[i], b = stops[min(i + 1, stops.count - 1)]
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * k,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k, alpha: alpha).cgColor
    }
}

// MARK: - Композиция

final class Embroidery {
    let root = CALayer()
    private(set) var tracks: [Track] = []
    /// Группы анимаций (для замеров): 1 коса, 2 мотивы, 4 тризуб. defaults write ua.vyshyvka.bar animParts -int N
    static var currentPart = 2
    static let period = 12.0                      // цикл плетения, с

    private let cx: CGFloat, cy: CGFloat, half: CGFloat
    private var trident: CAShapeLayer!

    /// Пикселей на pt при отрисовке (2 — Touch Bar; для крупных сцен — 2 × масштаб).
    let pixelScale: CGFloat

    /// «Шовк»: гладкі нитки без пунктиру стібків і тонші — для ніжних шпалер.
    let silk: Bool

    init(centerX: CGFloat, halfWidth: CGFloat, height: CGFloat = VB.barHeight, pixelScale: CGFloat = 2, silk: Bool = false) {
        cx = centerX; cy = height / 2; half = halfWidth; self.pixelScale = pixelScale; self.silk = silk
        root.frame = CGRect(x: 0, y: 0, width: VB.barWidth, height: height)
        build()
    }

    // MARK: геометрия

    /// Нить косы j на правой стороне (d — расстояние от тризуба).
    private func strandPoints(_ j: Int, length L: CGFloat, sway: CGFloat = 0) -> [CGPoint] {
        let lambda: CGFloat = 54
        let phi = CGFloat(j) * 2 * .pi / 3
        if !silk {
            return stride(from: 0, through: L, by: 1.5).map { d -> CGPoint in
                let env = CGFloat(smoothstep(Double(d / 22)))
                let amp = 6.6 * (1 - 0.38 * d / L)
                let off = -6.5 * exp(-d / 9)                       // рождение у основания тризуба
                return CGPoint(x: cx + 5 + d, y: cy + off + env * amp * sin(2 * .pi * d / lambda + phi))
            }
        }
        // «Шовк»: жива нитка — довжина хвилі й амплітуда плавно змінюються, у кожної пряді свій характер;
        // sway (0…1) — повільне погойдування, як шовк на легкому вітрі (сильніше до кінців).
        let jf = CGFloat(j)
        var theta = phi, out: [CGPoint] = []
        var d: CGFloat = 0
        while d <= L {
            let env = CGFloat(smoothstep(Double(d / 22)))
            let lam = lambda * (1 + 0.32 * sin(d / 37 + jf * 1.9) + 0.12 * sin(d / 13 + jf))
            let amp = 6.0 * (1 - 0.25 * d / L) * (1 + 0.42 * sin(d / 29 + jf * 2.3) + 0.12 * sin(d / 9 + jf * 0.7))
            let off = -6.5 * exp(-d / 9)
            let wander = 2.6 * sin(d / 53 + jf * 0.9) + 1.1 * sin(d / 23 + jf * 2.1)   // середня лінія блукає
            let flutter = 1.8 * (d / L) * sin(d / 19 - 2 * .pi * sway + jf * 1.3)
            out.append(CGPoint(x: cx + 5 + d, y: cy + off + env * (amp * sin(theta) + wander + flutter)))
            theta += 2 * .pi * 1.5 / lam
            d += 1.5
        }
        return out
    }

    /// Дополнительные анимации формы (только «шовк»), не через Track: ключевые кадры пути.
    private var shapeAnims: [(CALayer, CAKeyframeAnimation)] = []
    static let swayPeriod = 12.0
    /// Для «шовку» райдуга кратна циклу плетіння → сцена повністю періодична (безшовне відео).
    var rainbowPeriod: Double { silk ? Self.period : Rainbow.period }
    private var swayShapes: [(CAShapeLayer, (CGFloat) -> CGPath)] = []

    private func mirror(_ p: CGPath) -> CGPath {
        var t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * cx, ty: 0)
        return p.copy(using: &t)!
    }

    private func shape(_ path: CGPath, stroke: NSColor? = nil, fill: NSColor? = nil, width: CGFloat = 1,
                       into parent: CALayer, cap: CAShapeLayerLineCap = .round) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = path
        s.strokeColor = stroke?.cgColor
        s.fillColor = fill?.cgColor
        s.lineWidth = width
        s.lineCap = cap
        s.lineJoin = .round
        s.contentsScale = pixelScale
        s.frame = root.bounds
        parent.addSublayer(s)
        return s
    }

    private func group(_ center: CGPoint, into parent: CALayer, raster: Bool = true) -> CALayer {
        let g = CALayer()
        // Мотив растеризуется один раз; анимация масштаба/прозрачности двигает готовую текстуру
        g.shouldRasterize = raster
        g.rasterizationScale = pixelScale
        g.bounds = root.bounds
        g.anchorPoint = CGPoint(x: center.x / root.bounds.width, y: center.y / root.bounds.height)
        g.position = center
        parent.addSublayer(g)
        return g
    }

    // MARK: мотивы (координаты в pt, y вверх)

    private func petal(_ c: CGPoint, angle: CGFloat, len: CGFloat, wid: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let tip = CGPoint(x: c.x + len * cos(angle), y: c.y + len * sin(angle))
        let n = CGPoint(x: -sin(angle) * wid, y: cos(angle) * wid)
        let m = CGPoint(x: c.x + 0.5 * len * cos(angle), y: c.y + 0.5 * len * sin(angle))
        p.move(to: c)
        p.addQuadCurve(to: tip, control: CGPoint(x: m.x + n.x, y: m.y + n.y))
        p.addQuadCurve(to: c, control: CGPoint(x: m.x - n.x, y: m.y - n.y))
        p.closeSubpath()
        return p
    }

    /// Большая восьмилепестковая «рожа».
    private func rose(_ c: CGPoint, r: CGFloat, into g: CALayer, light: Bool = false) {
        let outer = CGMutablePath(), inner = CGMutablePath(), veins = CGMutablePath()
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4 + .pi / 8
            outer.addPath(petal(c, angle: a, len: r, wid: r * 0.34))
            inner.addPath(petal(c, angle: a + .pi / 8, len: r * 0.62, wid: r * 0.2))
            veins.move(to: CGPoint(x: c.x + 0.25 * r * cos(a), y: c.y + 0.25 * r * sin(a)))
            veins.addLine(to: CGPoint(x: c.x + 0.8 * r * cos(a), y: c.y + 0.8 * r * sin(a)))
        }
        _ = shape(outer, stroke: (light ? VB.red : VB.ivory).withAlphaComponent(0.55), fill: light ? VB.cream : VB.red, width: 0.45, into: g)
        _ = shape(inner, fill: light ? VB.red : VB.bordo, into: g)
        _ = shape(veins, stroke: (light ? VB.bordo : VB.ivory).withAlphaComponent(0.75), width: 0.4, into: g)
        let core = CGMutablePath()
        core.addEllipse(in: CGRect(x: c.x - r * 0.2, y: c.y - r * 0.2, width: r * 0.4, height: r * 0.4))
        _ = shape(core, fill: VB.ivory, into: g)
        let dots = CGMutablePath()
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4
            let p = CGPoint(x: c.x + r * 0.34 * cos(a), y: c.y + r * 0.34 * sin(a))
            dots.addEllipse(in: CGRect(x: p.x - 0.45, y: p.y - 0.45, width: 0.9, height: 0.9))
        }
        _ = shape(dots, fill: VB.cream, into: g)
    }

    private func flower(_ c: CGPoint, r: CGFloat, petals: Int, petalColor: NSColor, center: NSColor, into g: CALayer) {
        let p = CGMutablePath()
        for k in 0..<petals {
            p.addPath(petal(c, angle: CGFloat(k) * 2 * .pi / CGFloat(petals) + .pi / 2, len: r, wid: r * 0.42))
        }
        _ = shape(p, fill: petalColor, into: g)
        let core = CGMutablePath()
        core.addEllipse(in: CGRect(x: c.x - r * 0.28, y: c.y - r * 0.28, width: r * 0.56, height: r * 0.56))
        _ = shape(core, fill: center, into: g)
    }

    /// Крестик-стежок.
    private func cross(_ p: CGMutablePath, _ c: CGPoint, _ s: CGFloat) {
        p.move(to: CGPoint(x: c.x - s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
        p.move(to: CGPoint(x: c.x + s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
    }

    /// Вышитый голубь, смотрит к центру (dir = -1 на правой стороне).
    private func dove(_ c: CGPoint, s: CGFloat, dir: CGFloat, into g: CALayer) -> CALayer {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + dir * x * s, y: c.y + y * s) }
        let body = CGMutablePath()
        body.move(to: P(6.2, 1.6))                                  // клюв
        body.addLine(to: P(5.0, 2.1))
        body.addQuadCurve(to: P(3.6, 1.2), control: P(4.3, 2.6))    // голова
        body.addQuadCurve(to: P(-2.6, -1.6), control: P(1.2, -2.4))  // грудь/брюшко
        body.addLine(to: P(-6.4, -0.2))                             // хвост
        body.addLine(to: P(-5.8, -2.6))
        body.addQuadCurve(to: P(3.0, 0.2), control: P(-0.2, -0.4))
        body.addQuadCurve(to: P(5.0, 1.4), control: P(4.4, 0.6))
        body.closeSubpath()
        _ = shape(body, fill: VB.ivory, into: g)
        let wingLayer = group(P(0.4, 0.6), into: g)
        let wing = CGMutablePath()
        wing.move(to: P(0.4, 0.6))
        wing.addQuadCurve(to: P(-4.2, 4.6), control: P(-0.6, 4.8))
        wing.addQuadCurve(to: P(-1.6, 2.0), control: P(-2.2, 2.4))
        wing.addQuadCurve(to: P(0.4, 0.6), control: P(-0.4, 1.0))
        _ = shape(wing, fill: VB.cream, into: wingLayer)
        let stitches = CGMutablePath()
        for k in 0..<3 {
            let a = P(-0.6 - CGFloat(k) * 1.05, 1.5 + CGFloat(k) * 0.9), b = P(-1.4 - CGFloat(k) * 1.05, 2.4 + CGFloat(k) * 0.9)
            stitches.move(to: a); stitches.addLine(to: b)
        }
        _ = shape(stitches, stroke: VB.red, width: 0.55, into: wingLayer)
        let eye = CGMutablePath()
        eye.addEllipse(in: CGRect(x: P(4.5, 1.55).x - 0.35, y: P(4.5, 1.55).y - 0.35, width: 0.7, height: 0.7))
        _ = shape(eye, fill: VB.red, into: g)
        return wingLayer
    }

    /// Веточка с перистыми листьями: стебель + листья, раскрывающиеся по мере роста.
    private func sprig(from a: CGPoint, up: Bool, length: CGFloat, outward: CGFloat, into g: CALayer,
                       reveal: @escaping (Double) -> Double) {
        let dy: CGFloat = up ? 1 : -1
        let b = CGPoint(x: a.x + outward * length * 0.9, y: a.y + dy * length * 0.42)
        let stem = CGMutablePath()
        stem.move(to: a)
        stem.addQuadCurve(to: b, control: CGPoint(x: a.x + outward * length * 0.35, y: a.y + dy * length * 0.5))
        let sl = shape(stem, stroke: VB.cream.withAlphaComponent(0.9), width: 0.7, into: g)
        tracks.append(Track(layer: sl, key: "strokeEnd", period: Self.period) { t in CGFloat(clamp01(reveal(t) * 1.15)) })
        for k in 0..<4 {
            let f = 0.28 + CGFloat(k) * 0.22
            let p = CGPoint(x: a.x + outward * length * 0.9 * f, y: a.y + dy * length * 0.42 * f + dy * length * 0.5 * f * (1 - f) * 0.9)
            let side: CGFloat = k % 2 == 0 ? 1 : -1
            let ang = atan2(dy * 0.42, outward * 0.9) + side * 0.85
            let leafG = group(p, into: g)
            let colors = [VB.red, VB.cream, VB.ivory, VB.red]
            _ = shape(petal(p, angle: ang, len: 3.6 - CGFloat(k) * 0.35, wid: 1.25), fill: colors[k], into: leafG)
            let thr = Double(f)
            tracks.append(Track(layer: leafG, key: "transform", period: Self.period) { t in
                let r = smoothstep((reveal(t) - thr) / 0.18)
                return NSValue(caTransform3D: CATransform3DMakeScale(CGFloat(r), CGFloat(r), 1))
            })
        }
        // ягодка на конце
        let berry = group(b, into: g)
        let bp = CGMutablePath(); bp.addEllipse(in: CGRect(x: b.x - 1.1, y: b.y - 1.1, width: 2.2, height: 2.2))
        _ = shape(bp, fill: VB.red, into: berry)
        tracks.append(Track(layer: berry, key: "transform", period: Self.period) { t in
            let r = smoothstep((reveal(t) - 0.9) / 0.1)
            return NSValue(caTransform3D: CATransform3DMakeScale(CGFloat(r), CGFloat(r), 1))
        })
    }

    // MARK: сборка

    private func build() {
        let L = half - 8
        let skeleton = CALayer(); skeleton.frame = root.bounds; skeleton.opacity = silk ? 0.07 : 0.16
        skeleton.shouldRasterize = true; skeleton.rasterizationScale = pixelScale
        let braid = CALayer(); braid.frame = root.bounds
        let motifs = CALayer(); motifs.frame = root.bounds
        root.addSublayer(skeleton); root.addSublayer(braid); root.addSublayer(motifs)

        let strandStyle: [(NSColor, CGFloat)] = [(VB.ivory, 1.3), (VB.red, 1.35), (NSColor(hex: 0x4C678E), 0.95)]
        // Стороны: правая (s = 0) и левая (s = 1, зеркально, со сдвигом фазы — «разные, но гармоничные»)
        for side in 0..<2 {
            let mirrorSide = side == 1
            let sideShift = mirrorSide ? 0.17 : 0.0
            let outward: CGFloat = mirrorSide ? -1 : 1
            func M(_ p: CGPath) -> CGPath { mirrorSide ? mirror(p) : p }
            func X(_ d: CGFloat) -> CGFloat { cx + outward * (5 + d) }

            // Три пряди, фазы разнесены на треть цикла → лента никогда не пустеет
            Self.currentPart = 1
            var weaves: [Weave] = []
            for j in 0..<3 {
                var w = Weave()
                w.grow = [0.40, 0.36, 0.44][j]; w.hold = [0.18, 0.22, 0.14][j]
                weaves.append(w)
                let delta = Double(j) / 3 + sideShift
                let pts = strandPoints(j, length: L)
                // каркас — вся нить, низкий контраст
                let full = CGMutablePath(); full.addLines(between: pts)
                _ = shape(M(full), stroke: strandStyle[j].0, width: strandStyle[j].1 * 0.8, into: skeleton)

                // сегменты по трети волны: чередование «над/под»
                var lengths: [CGFloat] = [0]
                for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
                let total = lengths.last!
                let segLen: CGFloat = 27
                var i0 = 0, k = 0
                while i0 < pts.count - 1 {
                    var i1 = i0
                    while i1 < pts.count - 1 && lengths[i1] - lengths[i0] < segLen { i1 += 1 }
                    let seg = CGMutablePath(); seg.addLines(between: Array(pts[i0...i1]))
                    let s0 = Double(lengths[i0] / total), s1 = Double(lengths[i1] / total)
                    let z = CGFloat((k + j) % 3)
                    let holder = CALayer(); holder.frame = root.bounds; holder.zPosition = z
                    braid.addSublayer(holder)
                    let gap = shape(M(seg), stroke: VB.bg, width: strandStyle[j].1 + 1.5, into: holder, cap: .butt)
                    let thread = shape(M(seg), stroke: strandStyle[j].0, width: strandStyle[j].1, into: holder, cap: .butt)
                    if !silk { thread.lineDashPattern = [2.3, 0.55] }   // гладь стежками; на шпалерах — шовк
                    else { thread.lineWidth = strandStyle[j].1 * 0.75; thread.opacity = 0.72; gap.removeFromSuperlayer() }
                    let w = weaves[j]
                    if silk {
                        let K = 12
                        let a = CAKeyframeAnimation(keyPath: "path")
                        let lo = i0, hi = i1          // фіксуємо індекси (i0/i1 змінюються далі в циклі)
                        let shapeAt: (CGFloat) -> CGPath = { [unowned self] q in
                            let sp = self.strandPoints(j, length: L, sway: q)
                            let p = CGMutablePath(); p.addLines(between: Array(sp[lo...min(hi, sp.count - 1)])); return M(p)
                        }
                        a.values = (0...K).map { shapeAt(CGFloat($0) / CGFloat(K)) }
                        swayShapes.append((thread, shapeAt))
                        a.duration = Self.swayPeriod
                        a.calculationMode = .cubic
                        a.repeatCount = .infinity
                        shapeAnims.append((thread, a))
                    }
                    for l in (silk ? [thread] : [gap, thread]) {
                        tracks.append(Track(layer: l, key: "strokeEnd", period: Self.period) { t in
                            let f = w.front(frac(t / Self.period + delta))
                            return CGFloat(clamp01((f - s0) / max(0.0001, s1 - s0)))
                        })
                    }
                    // у самого тризуба нить подхватывает его текущий оттенок
                    if k == 0 {
                        let tint = shape(M(seg), stroke: VB.ivory, width: strandStyle[j].1, into: holder)
                        tint.strokeEnd = 0.6
                        let rp = rainbowPeriod
                        tracks.append(Track(layer: tint, key: "strokeColor", period: rp) { t in Rainbow.color(t, alpha: 0.55, period: rp) })
                        tracks.append(Track(layer: tint, key: "opacity", period: Self.period) { t in
                            Float(smoothstep(w.front(frac(t / Self.period + delta)) / 0.05))
                        })
                    }
                    i0 = i1; k += 1
                }
            }
            Self.currentPart = 2
            func reveal(_ j: Int, at d: CGFloat, delay: Double = 0) -> (Double) -> Double {
                let w = weaves[j], delta = Double(j) / 3 + sideShift + delay, f = Double(d / L)
                return { t in clamp01((w.front(frac(t / Self.period + delta)) - f) / 0.1) }
            }
            func bloom(_ g: CALayer, _ r: @escaping (Double) -> Double, spin: CGFloat = 0) {
                tracks.append(Track(layer: g, key: "transform", period: Self.period) { t in
                    let v = CGFloat(smoothstep(r(t)))
                    var tr = CATransform3DMakeScale(0.2 + 0.8 * v, 0.2 + 0.8 * v, 1)
                    tr = CATransform3DRotate(tr, spin * (1 - v), 0, 0, 1)
                    return NSValue(caTransform3D: tr)
                })
                tracks.append(Track(layer: g, key: "opacity", period: Self.period) { t in Float(smoothstep(r(t) * 1.6)) })
            }

            // Уровень 2: листья-«перья» на гребнях косы
            var kk = 0
            var dLeaf: CGFloat = 20
            while dLeaf < L - 14 {
                let busy = (58...84).contains(dLeaf) || (138...162).contains(dLeaf) || (176...198).contains(dLeaf) || (104...120).contains(dLeaf)
                if !busy {
                    let up = kk % 2 == 0
                    let amp = 6.6 * (1 - 0.38 * dLeaf / L)
                    let base = CGPoint(x: X(dLeaf), y: cy + (up ? amp - 0.4 : -amp + 0.4))
                    let g = group(base, into: motifs)
                    let ang: CGFloat = (up ? .pi / 2 : -.pi / 2) + outward * (up ? -0.6 : 0.6)
                    let leaves = CGMutablePath()
                    leaves.addPath(petal(base, angle: ang, len: 4.8, wid: 1.55))
                    leaves.addPath(petal(base, angle: ang + outward * (up ? 0.95 : -0.95), len: 3.4, wid: 1.2))
                    let fillC = [VB.red, VB.cream, VB.bordo][kk % 3]
                    _ = shape(leaves, fill: fillC, into: g)
                    let vein = CGMutablePath(); vein.move(to: base)
                    vein.addLine(to: CGPoint(x: base.x + 3.8 * cos(ang), y: base.y + 3.8 * sin(ang)))
                    _ = shape(vein, stroke: VB.ivory.withAlphaComponent(0.55), width: 0.35, into: g)
                    bloom(g, reveal(kk % 3, at: dLeaf), spin: outward * 0.5)
                    kk += 1
                }
                dLeaf += 13.5
            }

            // Розы: большая красная и светлая
            for (d, r, light, j) in [(CGFloat(70), CGFloat(10.6), false, 0), (CGFloat(150), CGFloat(8.6), true, 1)] {
                let c = CGPoint(x: X(d), y: cy)
                let rg = group(c, into: motifs)
                rose(c, r: r, into: rg, light: light)
                bloom(rg, reveal(j, at: d - 10), spin: outward * 0.6)
                let rk = CGMutablePath(); rk.addEllipse(in: CGRect(x: c.x - r * 0.85, y: c.y - r * 0.85, width: r * 1.7, height: r * 1.7))
                _ = shape(rk, stroke: VB.red, width: 0.6, into: skeleton)
            }

            // Геометрические розетки крестиком (ромб-«рожа» из стежков)
            for (d, rr, j) in [(CGFloat(112), 4, 2), (CGFloat(224), 3, 0)] {
                let c = CGPoint(x: X(d), y: cy)
                let g = group(c, into: motifs)
                let edge = CGMutablePath(), body = CGMutablePath(), core = CGMutablePath()
                let st: CGFloat = 1.35
                for gy in -rr...rr { for gx in -rr...rr {
                    let m = abs(gx) + abs(gy)
                    guard m <= rr else { continue }
                    let p = CGPoint(x: c.x + CGFloat(gx) * st, y: c.y + CGFloat(gy) * st)
                    if m == rr { cross(edge, p, 0.55) } else if m == 0 || (gx == 0 || gy == 0) && m == 1 { cross(core, p, 0.55) }
                    else if (gx + gy) % 2 == 0 { cross(body, p, 0.55) }
                } }
                let bgDisk = CGMutablePath()
                bgDisk.move(to: CGPoint(x: c.x, y: c.y + CGFloat(rr + 1) * st)); bgDisk.addLine(to: CGPoint(x: c.x + CGFloat(rr + 1) * st, y: c.y))
                bgDisk.addLine(to: CGPoint(x: c.x, y: c.y - CGFloat(rr + 1) * st)); bgDisk.addLine(to: CGPoint(x: c.x - CGFloat(rr + 1) * st, y: c.y)); bgDisk.closeSubpath()
                _ = shape(bgDisk, fill: VB.bg, into: g)
                _ = shape(edge, stroke: VB.red, width: 0.6, into: g, cap: .butt)
                _ = shape(body, stroke: VB.cream, width: 0.55, into: g, cap: .butt)
                _ = shape(core, stroke: VB.ivory, width: 0.6, into: g, cap: .butt)
                bloom(g, reveal(j, at: d - 6), spin: outward * 0.8)
            }

            // Веточки
            sprig(from: CGPoint(x: X(14), y: cy + 4), up: true, length: 24, outward: outward, into: motifs, reveal: reveal(1, at: 10))
            sprig(from: CGPoint(x: X(36), y: cy - 4), up: false, length: 22, outward: outward, into: motifs, reveal: reveal(2, at: 30))
            sprig(from: CGPoint(x: X(100), y: cy + 3), up: true, length: 22, outward: outward, into: motifs, reveal: reveal(1, at: 96))
            sprig(from: CGPoint(x: X(122), y: cy - 3), up: false, length: 22, outward: outward, into: motifs, reveal: reveal(2, at: 118))
            sprig(from: CGPoint(x: X(206), y: cy + 3), up: true, length: 20, outward: outward, into: motifs, reveal: reveal(0, at: 202))

            // Малые цветы сверху/снизу
            let small: [(CGFloat, CGFloat, Int, NSColor, NSColor, Int)] = [
                (30, cy + 10.8, 6, VB.ivory, VB.red, 2), (48, cy - 10.8, 5, VB.red, VB.ivory, 1),
                (92, cy - 10.8, 8, VB.red, VB.cream, 0), (130, cy + 10.8, 6, VB.cream, VB.red, 2),
                (168, cy - 10.8, 5, VB.ivory, VB.red, 1), (196, cy - 10.6, 6, VB.red, VB.ivory, 0),
                (240, cy + 10.4, 5, VB.cream, VB.red, 2),
            ]
            for (d, y, n, pc, cc, j) in small where d < L - 4 {
                let c = CGPoint(x: X(d), y: y)
                let g = group(c, into: motifs)
                flower(c, r: 3.7, petals: n, petalColor: pc, center: cc, into: g)
                bloom(g, reveal(j, at: d - 6), spin: outward * 0.9)
            }

            // Голубь, смотрит к тризубу
            let doveC = CGPoint(x: X(186), y: cy + 0.8)
            let dg = group(doveC, into: motifs)
            let wing = dove(doveC, s: 1.3, dir: -outward, into: dg)
            bloom(dg, reveal(0, at: 176))
            tracks.append(Track(layer: wing, key: "transform", period: Self.period / 4) { t in
                NSValue(caTransform3D: CATransform3DMakeRotation(outward * 0.09 * CGFloat(sin(2 * .pi * t / (Self.period / 4))), 0, 0, 1))
            })

            if !silk {
            // Полосы ромбов крестиком у дальних краёв
            for (row, y) in [(0, CGFloat(2.9)), (1, CGFloat(27.1))] {
                var d: CGFloat = 214
                var n = 0
                while d < L - 1 {
                    let c = CGPoint(x: X(d), y: y)
                    let g = group(c, into: motifs)
                    let p = CGMutablePath()
                    for (ox, oy) in [(0, 1.7), (-1.7, 0), (1.7, 0), (0, -1.7), (0, 0)] as [(CGFloat, CGFloat)] {
                        cross(p, CGPoint(x: c.x + ox, y: c.y + oy), 0.7)
                    }
                    _ = shape(p, stroke: n % 2 == 0 ? VB.red : VB.cream, width: 0.6, into: g, cap: .butt)
                    bloom(g, reveal(1, at: d + CGFloat(row) * 6 - 8))
                    d += 9; n += 1
                }
            }

            }
            // Уровень 3: мелкие стежки (на «шовку» — без прямих рядів)
            if !silk {
            var d: CGFloat = 8
            var n = 0
            while d < L - 6 {
                for y in [cy + 13.2, cy - 13.2] {
                    let c = CGPoint(x: X(d + (y > cy ? 0 : 5)), y: y)
                    let g = group(c, into: motifs)
                    let p = CGMutablePath(); cross(p, c, 0.6)
                    _ = shape(p, stroke: (n % 3 == 0) ? VB.cream : VB.bordo, width: 0.5, into: g, cap: .butt)
                    bloom(g, reveal(n % 3, at: d))
                }
                d += 10; n += 1
            }
            }
        }

        Self.currentPart = 4
        // Тризуб — радужное сердце, всегда видим
        let tp = Tryzub.path(height: 23, centerX: cx, baseY: cy - 11.5)
        if !silk {
            let halo = shape(tp, stroke: VB.ivory, width: 3.0, into: root)
            halo.opacity = 0.26
            tracks.append(Track(layer: halo, key: "strokeColor", period: Rainbow.period) { t in Rainbow.color(t) })   // лише Touch Bar
        }
        trident = shape(tp, fill: VB.ivory, into: root)
        if silk {
            // шпалери: повна чіткість і тонкий лляний кант — силует читається цілісно
            trident.contentsScale = pixelScale * 2
            trident.strokeColor = VB.ivory.withAlphaComponent(0.55).cgColor
            trident.lineWidth = 0.22
        }
        let rp = rainbowPeriod
        tracks.append(Track(layer: trident, key: "fillColor", period: rp) { t in Rainbow.color(t, period: rp) })
    }

    // MARK: - Применение

    /// Модельные значения на момент t (предпросмотр, Reduce Motion).
    func apply(time t: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for tr in tracks { tr.layer.setValue(tr.fn(t), forKeyPath: tr.key) }
        for (l, f) in swayShapes { l.path = f(CGFloat(frac(t / Self.swayPeriod))) }
        CATransaction.commit()
    }

    /// Ключевые кадры для рендер-сервера; fps — частота опорных точек и кадров.
    func start(fps: Int, begin: CFTimeInterval = CACurrentMediaTime()) {
        stop()
        let mask = UserDefaults.standard.object(forKey: "animParts") as? Int ?? 7
        for tr in tracks where tr.part & mask != 0 {
            let n = max(2, Int(tr.period * Double(min(fps, 30))))   // опорные точки; CA интерполирует между ними
            let a = CAKeyframeAnimation(keyPath: tr.key)
            a.values = (0...n).map { tr.fn(tr.period * Double($0) / Double(n)) }
            a.duration = tr.period
            a.calculationMode = .linear
            a.repeatCount = .infinity
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            if #available(macOS 12.0, *) {
                let f = Float(fps)
                a.preferredFrameRateRange = CAFrameRateRange(minimum: min(15, f), maximum: f, preferred: f)
            }
            tr.layer.add(a, forKey: "v5." + tr.key)
        }
            for (l, a) in shapeAnims {
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            if #available(macOS 12.0, *) {
                let f = Float(fps)
                a.preferredFrameRateRange = CAFrameRateRange(minimum: min(15, f), maximum: f, preferred: f)
            }
            l.add(a, forKey: "v5.sway")
        }
    }

    func stop() {
        for tr in tracks { tr.layer.removeAnimation(forKey: "v5." + tr.key) }
        for (l, _) in shapeAnims { l.removeAnimation(forKey: "v5.sway") }
    }

    var layerCount: Int {
        func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
        return count(root)
    }
}
