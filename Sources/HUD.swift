import AppKit
import QuartzCore

/// Індикатор гучності/яскравості на екрані (як системний, але у стилі вишивки):
/// темна плашка внизу по центру, іконка і суцільна полоска рівня. Не перехоплює мишу й фокус.
final class LevelHUD: NSPanel {
    enum Kind { case volume, brightness }
    static let shared = LevelHUD()

    private let root = CALayer()
    private let iconLayer = CALayer()
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private static let barRect = CGRect(x: 72, y: 29, width: 206, height: 6)
    private var hideJob: DispatchWorkItem?
    private static let size = NSSize(width: 300, height: 64)

    private init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: Self.size))
        v.wantsLayer = true
        v.layer = root
        root.backgroundColor = NSColor(hex: 0x0E0D10, alpha: 0.92).cgColor
        root.cornerRadius = 18
        root.borderWidth = 0.8
        root.borderColor = VB.cream.withAlphaComponent(0.22).cgColor
        root.contentsScale = 2
        contentView = v
        iconLayer.frame = CGRect(x: 18, y: 16, width: 40, height: 32)
        root.addSublayer(iconLayer)
        // Суцільна полоска: ледь помітна доріжка + заповнення від червоного до кремового
        track.frame = Self.barRect
        track.cornerRadius = 3
        track.backgroundColor = VB.ivory.withAlphaComponent(0.14).cgColor
        root.addSublayer(track)
        fill.frame = CGRect(origin: Self.barRect.origin, size: CGSize(width: 0, height: Self.barRect.height))
        fill.cornerRadius = 3
        fill.colors = [VB.red.cgColor, NSColor(hex: 0xD9586A).cgColor, VB.cream.cgColor]
        fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
        root.addSublayer(fill)
    }

    /// value 0…1; muted — для гучності 0.
    func show(_ kind: Kind, value: Float) {
        let v = max(0, min(1, value))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        iconLayer.sublayers = nil
        let g = kind == .volume ? Icons.speaker(strong: v > 0.5) : Icons.sun(strong: v > 0.5)
        let k: CGFloat = 1.7
        let holder = CALayer()
        holder.frame = CGRect(x: (iconLayer.bounds.width - g.size.width * k) / 2, y: (iconLayer.bounds.height - g.size.height * k) / 2,
                              width: g.size.width, height: g.size.height)
        holder.anchorPoint = .zero
        holder.position = CGPoint(x: (iconLayer.bounds.width - g.size.width * k) / 2, y: (iconLayer.bounds.height - g.size.height * k) / 2)
        holder.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        func add(_ p: CGPath, stroke: NSColor?, fill: NSColor?) {
            let s = CAShapeLayer(); s.path = p; s.strokeColor = stroke?.cgColor; s.fillColor = fill?.cgColor
            s.lineWidth = VB.stroke; s.lineCap = .round; s.lineJoin = .round; s.contentsScale = 4
            holder.addSublayer(s)
        }
        add(g.fillAccent, stroke: nil, fill: VB.red); add(g.fillInk, stroke: nil, fill: VB.ivory)
        add(g.ink, stroke: VB.ivory, fill: nil); add(g.accent, stroke: VB.red, fill: nil)
        iconLayer.addSublayer(holder)
        CATransaction.commit()
        // заповнення плавно доїжджає до нового значення
        CATransaction.begin(); CATransaction.setAnimationDuration(isVisible && alphaValue > 0 ? 0.12 : 0)
        fill.frame = CGRect(origin: Self.barRect.origin, size: CGSize(width: Self.barRect.width * CGFloat(v), height: Self.barRect.height))
        CATransaction.commit()

        if let s = NSScreen.main {
            let f = s.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 90))
        }
        hideJob?.cancel()
        if !isVisible || alphaValue < 1 {
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        let job = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; self?.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                if self?.alphaValue == 0 { self?.orderOut(nil) }
            })
        }
        hideJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: job)
    }
}
