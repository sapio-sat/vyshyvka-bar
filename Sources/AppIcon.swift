import AppKit

/// Іконка програми (1024×1024): темне полотно, рамка хрестиком, веселковий тризуб із сяйвом.
///   VyshyvkaBar --icon out.png
enum AppIcon {
    static func render(size S: CGFloat = 1024) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let k = S / 1024
        ctx.scaleBy(x: k, y: k)
        // форма іконки macOS: 824×824, радіус ~185
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor(hex: 0x0A0A0D).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let bg = CGGradient(colorsSpace: cs, colors: [NSColor(hex: 0x1C1820).cgColor, NSColor(hex: 0x08080A).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 560, options: [])

        // рамка: ряд вишитих хрестиків (червоний/кремовий), як облямівка рушника
        let inset = body.insetBy(dx: 58, dy: 58)
        let step: CGFloat = 26, arm: CGFloat = 7.5
        ctx.setLineCap(.round); ctx.setLineWidth(4.2)
        var n = 0
        func stitch(_ p: CGPoint) {
            let c = n % 4 == 3 ? VB.cream : VB.red
            ctx.setStrokeColor(c.withAlphaComponent(0.9).cgColor)
            ctx.move(to: CGPoint(x: p.x - arm, y: p.y - arm)); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y + arm))
            ctx.move(to: CGPoint(x: p.x - arm, y: p.y + arm)); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y - arm))
            ctx.strokePath(); n += 1
        }
        let r: CGFloat = 120
        // прямі ділянки
        var x = inset.minX + r
        while x <= inset.maxX - r { stitch(CGPoint(x: x, y: inset.minY)); stitch(CGPoint(x: x, y: inset.maxY)); x += step }
        var y = inset.minY + r
        while y <= inset.maxY - r { stitch(CGPoint(x: inset.minX, y: y)); stitch(CGPoint(x: inset.maxX, y: y)); y += step }
        // кути
        for (cx, cy, a0) in [(inset.maxX - r, inset.maxY - r, 0.0), (inset.minX + r, inset.maxY - r, 90.0),
                             (inset.minX + r, inset.minY + r, 180.0), (inset.maxX - r, inset.minY + r, 270.0)] {
            let m = Int((CGFloat.pi / 2 * r) / step)
            for i in 1..<m {
                let a = (a0 + 90 * Double(i) / Double(m)) * .pi / 180
                stitch(CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a))))
            }
        }

        // тризуб: сяйво + веселкова заливка знизу догори
        let h: CGFloat = 470
        let tr = Tryzub.path(height: h, centerX: 512, baseY: 512 - h / 2 - 8)
        let colors = Rainbow.stops.reversed().map(\.cgColor) as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: nil)!
        for (blur, a) in [(90.0, 0.55), (36.0, 0.5)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: NSColor(hex: 0xFFB45A, alpha: a).cgColor)
            ctx.addPath(tr); ctx.setFillColor(NSColor(hex: 0xFFB45A, alpha: 0.35).cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(tr); ctx.clip()
        let bb = tr.boundingBox
        ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: bb.minY), end: CGPoint(x: 512, y: bb.maxY), options: [])
        ctx.restoreGState()
        // тонкий світлий контур — «шовкова нитка»
        ctx.addPath(tr); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor); ctx.setLineWidth(2.2); ctx.strokePath()
        ctx.restoreGState()
        return ctx.makeImage()!
    }
}
