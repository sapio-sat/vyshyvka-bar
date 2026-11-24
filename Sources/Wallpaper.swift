import AppKit
import AVFoundation
import CoreImage
import Metal
import QuartzCore

// Живі шпалери VYSHYVKA — зациклене відео.
// Сцена (та сама шовкова вишивка, сяйво, пилинки) один раз рендериться в безшовний HEVC-ролик
// циклом 36 с; на робочому столі його просто програє AVPlayerLooper (апаратне декодування).
// Вікно на рівні робочого столу: під іконками, без кліків, на всіх Spaces і моніторах.
// Системні шпалери не змінюються. Пауза, коли стіл закритий вікнами, екран погашений або «Зменшення руху».

enum WallpaperVideo {
    static let loop: Double = 36          // секунд; усі періоди сцени його ділять
    static let fps = 30
    static let version = 2

    static func url(for size: CGSize) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VYSHYVKA BAR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wallpaper-v\(version)-\(Int(size.width))x\(Int(size.height)).mov")
    }

    /// Рендер безшовного ролика (CLI: --wallpaper-video), масштаб 2 = Retina.
    static func render(size: CGSize, scale: CGFloat = 2, to out: URL, progress: (Int, Int) -> Void) throws {
        let scene = WallpaperScene(frame: NSRect(origin: .zero, size: size))
        let w = Int(size.width * scale) & ~1, h = Int(size.height * scale) & ~1
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoExpectedSourceFrameRateKey: fps]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        // GPU-рендер дерева шарів (CARenderer + Metal): у десятки разів швидше за CPU render(in:)
        guard let dev = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "wallpaper", code: 3) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .managed
        guard let tex = dev.makeTexture(descriptor: td), let cq = dev.makeCommandQueue() else { throw NSError(domain: "wallpaper", code: 4) }
        let renderer = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue as String: cq])
        let holder = CALayer()
        holder.frame = CGRect(x: 0, y: 0, width: w, height: h)
        holder.isGeometryFlipped = true      // у текстури Metal початок координат зверху
        let sceneLayer = scene.layer!
        sceneLayer.anchorPoint = .zero
        sceneLayer.position = .zero
        sceneLayer.transform = CATransform3DMakeScale(CGFloat(w) / size.width, CGFloat(h) / size.height, 1)
        holder.addSublayer(sceneLayer)
        renderer.layer = holder
        renderer.bounds = holder.frame
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "wallpaper", code: 1) }
        writer.startSession(atSourceTime: .zero)
        let n = Int(loop * Double(fps))
        for i in 0..<n {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { continue }
            scene.apply(at: Double(i) / Double(fps))
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            // дочекатися GPU і скопіювати кадр у буфер відео
            if let cb = cq.makeCommandBuffer(), let bl = cb.makeBlitCommandEncoder() {
                bl.synchronize(resource: tex); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
            CVPixelBufferLockBaseAddress(buf, [])
            tex.getBytes(CVPixelBufferGetBaseAddress(buf)!, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            if i % 30 == 0 { progress(i, n) }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "wallpaper", code: 2) }
    }
}

final class WallpaperController {
    private var windows: [WallpaperWindow] = []

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "wallpaper") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wallpaper"); newValue ? build() : teardown() }
    }

    func start() {
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        ws.addObserver(self, selector: #selector(updateMotion), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(pauseAll), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(pauseAll), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(updateMotion), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(updateMotion), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if enabled { build() }
    }

    @objc private func screensChanged() { if enabled { build() } }

    private var generator: Process?

    /// Ролика під цей екран ще немає (перший запуск) — один раз рендеримо у фоні, поки показується статичний кадр.
    private func generateMissingVideos() {
        guard generator == nil, let exe = Bundle.main.executableURL,
              NSScreen.screens.contains(where: { !FileManager.default.fileExists(atPath: WallpaperVideo.url(for: $0.frame.size).path) })
        else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--wallpaper-video"]
        p.qualityOfService = .utility
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.generator = nil
                if proc.terminationStatus == 0, self?.enabled == true { self?.build() }
            }
        }
        do { try p.run(); generator = p } catch {}
    }

    func build() {
        teardown()
        generateMissingVideos()
        for screen in NSScreen.screens {
            let w = WallpaperWindow(screen: screen)
            w.orderFront(nil)
            NotificationCenter.default.addObserver(self, selector: #selector(updateMotion),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: w)
            windows.append(w)
        }
        updateMotion()
    }

    func teardown() {
        for w in windows {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: w)
            w.player.stop(); w.orderOut(nil)
        }
        windows = []
    }

    @objc func updateMotion() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for w in windows {
            if !still && w.occlusionState.contains(.visible) { w.player.play() } else { w.player.pause() }
        }
    }

    @objc private func pauseAll() { windows.forEach { $0.player.pause() } }

    var windowNumbers: [Int] { windows.map { $0.windowNumber } }
    var modes: [String] { windows.map { $0.player.mode } }
}

final class WallpaperWindow: NSWindow {
    let player: WallpaperPlayerView

    init(screen: NSScreen) {
        player = WallpaperPlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = VB.bg
        isReleasedWhenClosed = false
        contentView = player
        setFrame(screen.frame, display: true)
    }
}

/// Програвач ролика; якщо ролика ще немає — показує статичний кадр тієї ж сцени.
final class WallpaperPlayerView: NSView {
    private var queue: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var mode = "static"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = VB.bg.cgColor
        let url = WallpaperVideo.url(for: frame.size)
        if FileManager.default.fileExists(atPath: url.path) {
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            let q = AVQueuePlayer()
            q.isMuted = true
            q.preventsDisplaySleepDuringVideoPlayback = false     // не заважає екрану засинати
            looper = AVPlayerLooper(player: q, templateItem: item)
            let pl = AVPlayerLayer(player: q)
            pl.videoGravity = .resizeAspectFill
            pl.frame = bounds
            pl.backgroundColor = VB.bg.cgColor
            layer?.addSublayer(pl)
            queue = q
            mode = "video"
        } else {
            // запасний варіант: нерухомий кадр сцени
            let scene = WallpaperScene(frame: bounds)
            let ctx = CGContext(data: nil, width: Int(bounds.width * 2), height: Int(bounds.height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: 2, y: 2)
            scene.render(at: 6, in: ctx)
            layer?.contents = ctx.makeImage()
            layer?.contentsGravity = .resizeAspectFill
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func play() { queue?.play() }
    func pause() { queue?.pause() }
    func stop() { queue?.pause(); looper?.disableLooping(); queue = nil; looper = nil }
}

/// Сцена шпалер: детермінована функція часу t ∈ [0, 36) с — для рендера кадрів ролика.
final class WallpaperScene: NSView {
    private let root = CALayer()
    private var embroidery: Embroidery!
    private var band = CALayer()
    private var glowLayer: CALayer?
    private var aura: CAGradientLayer!
    private var pools: [(CALayer, Double, Double)] = []                 // шар, період, фаза
    private var motes: [(CALayer, CGPoint, CGPoint, Double, Double)] = [] // шар, старт, фініш, період, фаза
    private static let calm = 1.0 / 3.0                                   // вишивка втричі повільніша, ніж на Touch Bar

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        root.backgroundColor = VB.bg.cgColor

        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.colors = [NSColor(hex: 0x1C0E13).cgColor, NSColor(hex: 0x0E0A0C).cgColor, VB.bg.cgColor]
        vignette.locations = [0, 0.45, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5); vignette.endPoint = CGPoint(x: 1.15, y: 1.25)
        vignette.frame = bounds
        root.addSublayer(vignette)

        // М’які світлові плями — відблиски сонця на спокійній воді; періоди ділять 36 с
        let spec: [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat, Double)] = [
            (0.50, 0.50, 0.62, 0xB0543F, 0.20, 36), (0.24, 0.56, 0.42, 0xB42D3E, 0.13, 18),
            (0.77, 0.45, 0.44, 0xD6BEA4, 0.09, 12), (0.50, 0.30, 0.55, 0x8C2233, 0.10, 36),
        ]
        for (k, (fx, fy, fr, hex, a, period)) in spec.enumerated() {
            let c = NSColor(hex: hex)
            let g = CAGradientLayer()
            g.type = .radial
            g.colors = [c.withAlphaComponent(a).cgColor, c.withAlphaComponent(a * 0.35).cgColor, c.withAlphaComponent(0).cgColor]
            g.locations = [0, 0.45, 1]
            g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
            let d = W * fr
            g.frame = CGRect(x: W * fx - d / 2, y: H * fy - d * 0.32, width: d, height: d * 0.64)
            root.addSublayer(g)
            pools.append((g, period, Double(k) * 0.23))
        }

        let s = max(3.2, min(6, W / 340))
        let bandW = W / s
        embroidery = Embroidery(centerX: bandW / 2, halfWidth: bandW / 2 - 4, height: VB.barHeight, pixelScale: 2 * s, silk: true)
        band.frame = CGRect(x: 0, y: H * 0.5 - VB.barHeight * s / 2, width: W, height: VB.barHeight * s)
        embroidery.root.anchorPoint = .zero
        embroidery.root.position = .zero
        embroidery.root.transform = CATransform3DMakeScale(s, s, 1)
        band.addSublayer(embroidery.root)
        band.opacity = 0.66
        root.addSublayer(band)
        embroidery.apply(time: 4)

        // Сяйво: одноразово розмитий знімок вишивки під узором
        if let img = Self.blurredSnapshot(of: band, radius: 9 * (s / 4)) {
            let glow = CALayer()
            glow.frame = band.frame.insetBy(dx: 0, dy: -band.frame.height * 0.6)
            glow.contents = img
            glow.contentsGravity = .resize
            root.insertSublayer(glow, below: band)
            glowLayer = glow
        }

        // Райдужний ореол навколо тризуба
        aura = CAGradientLayer()
        aura.type = .radial
        aura.startPoint = CGPoint(x: 0.5, y: 0.5); aura.endPoint = CGPoint(x: 1, y: 1)
        aura.locations = [0, 0.5, 1]
        let ad = VB.barHeight * s * 2.6
        aura.frame = CGRect(x: W / 2 - ad / 2, y: H * 0.5 - ad / 2, width: ad, height: ad)
        root.insertSublayer(aura, below: band)

        // Пилинки в теплому повітрі: періоди 12/18/36 с
        var seed: UInt64 = 0x5EED
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        for k in 0..<16 {
            let m = CALayer()
            let r = 1.2 + rnd() * 1.6
            m.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            m.cornerRadius = r
            m.backgroundColor = (rnd() > 0.6 ? VB.ivory : VB.cream).withAlphaComponent(0.55).cgColor
            let x = W * (0.12 + rnd() * 0.76), y0 = H * (0.3 + rnd() * 0.3)
            let a = CGPoint(x: x, y: y0), b = CGPoint(x: x + (rnd() - 0.5) * 60, y: y0 + 70 + rnd() * 60)
            root.addSublayer(m)
            motes.append((m, a, b, [12.0, 18.0, 36.0][k % 3], Double(rnd())))
        }
    }

    /// Стан усієї сцени на момент t (с, реальний час ролика).
    func apply(at t: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        embroidery.apply(time: t * Self.calm)                 // 36 с ролика = один цикл плетіння (12 с)
        for (g, period, phase) in pools {
            g.opacity = Float(0.45 + 0.55 * (0.5 - 0.5 * cos(2 * .pi * (t / period + phase))))
        }
        glowLayer?.opacity = Float(0.55 + 0.4 * (0.5 - 0.5 * cos(2 * .pi * t / 18)))
        let rp = embroidery.rainbowPeriod / Self.calm         // 36 с
        aura.colors = [Rainbow.color(t, alpha: 0.16, period: rp), Rainbow.color(t, alpha: 0.05, period: rp), Rainbow.color(t, alpha: 0, period: rp)]
        for (m, a, b, period, phase) in motes {
            let u = frac(t / period + phase)
            let e = u * u * (3 - 2 * u)
            m.position = CGPoint(x: a.x + (b.x - a.x) * CGFloat(e), y: a.y + (b.y - a.y) * CGFloat(e))
            m.opacity = Float((u < 0.3 ? u / 0.3 : (u > 0.7 ? (1 - u) / 0.3 : 1)) * 0.85)
        }
        CATransaction.commit()
    }

    func render(at t: Double, in ctx: CGContext) {
        apply(at: t)
        root.render(in: ctx)
    }

    static func blurredSnapshot(of band: CALayer, radius: CGFloat) -> CGImage? {
        let pad = band.bounds.height * 0.6
        let size = CGSize(width: band.bounds.width, height: band.bounds.height + 2 * pad)
        let scale: CGFloat = 0.5
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: pad)
        band.render(in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: Double(radius * scale))
            .cropped(to: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        let warm = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputBrightnessKey: 0.02])
        return CIContext().createCGImage(warm, from: warm.extent)
    }
}
