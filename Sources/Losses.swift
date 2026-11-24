import AppKit
import QuartzCore

// Зведення Генштабу ЗСУ про втрати противника + день війни.
// Первоисточник — щоденні повідомлення Генерального штабу ЗСУ (пост у кожному звіті).
// Машиночитані дані — відкритий API russianwarship.rip (агрегує ті самі зведення, дає посилання на пост ГШ).
// День війни рахується локально: 24.02.2022 = 1-й день, київський час.

struct LossReport: Codable {
    var date: String           // yyyy-MM-dd, станом на
    var day: Int               // доба війни у зведенні
    var resource: String?      // посилання на допис Генштабу
    var stats: [String: Int]
    var increase: [String: Int]
    var fetchedAt: Date
}

enum Losses {
    static let order = ["personnel_units", "tanks", "armoured_fighting_vehicles", "artillery_systems", "mlrs",
                        "aa_warfare_systems", "planes", "helicopters", "uav_systems", "cruise_missiles",
                        "warships_cutters", "submarines", "vehicles_fuel_tanks", "special_military_equip", "atgm_srbm_systems"]
    // Короткі назви, як у щоденних зведеннях ГШ (повні назви API не вміщаються в рядок)
    static var titles: [String: String] { L.lang == "en" ? titlesEN : L.lang == "ru" ? titlesRU : titlesUK }
    static let titlesEN: [String: String] = [
        "personnel_units": "Personnel", "tanks": "Tanks", "armoured_fighting_vehicles": "Armoured vehicles",
        "artillery_systems": "Artillery systems", "mlrs": "MLRS", "aa_warfare_systems": "Air defence systems",
        "planes": "Aircraft", "helicopters": "Helicopters", "uav_systems": "UAVs",
        "cruise_missiles": "Cruise missiles", "warships_cutters": "Warships / boats", "submarines": "Submarines",
        "vehicles_fuel_tanks": "Vehicles & fuel tanks", "special_military_equip": "Special equipment",
        "atgm_srbm_systems": "Tactical missile systems",
    ]
    static let titlesRU: [String: String] = [
        "personnel_units": "Личный состав", "tanks": "Танки", "armoured_fighting_vehicles": "ББМ",
        "artillery_systems": "Артиллерийские системы", "mlrs": "РСЗО", "aa_warfare_systems": "Средства ПВО",
        "planes": "Самолёты", "helicopters": "Вертолёты", "uav_systems": "БПЛА",
        "cruise_missiles": "Крылатые ракеты", "warships_cutters": "Корабли / катера", "submarines": "Подводные лодки",
        "vehicles_fuel_tanks": "Автотехника и цистерны", "special_military_equip": "Специальная техника",
        "atgm_srbm_systems": "ОТРК / ТРК",
    ]
    static let titlesUK: [String: String] = [
        "personnel_units": "Особовий склад", "tanks": "Танки", "armoured_fighting_vehicles": "Бойові броньовані машини",
        "artillery_systems": "Артилерійські системи", "mlrs": "РСЗВ", "aa_warfare_systems": "Засоби ППО",
        "planes": "Літаки", "helicopters": "Гелікоптери", "uav_systems": "БпЛА",
        "cruise_missiles": "Крилаті ракети", "warships_cutters": "Кораблі / катери", "submarines": "Підводні човни",
        "vehicles_fuel_tanks": "Автотехніка й цистерни", "special_military_equip": "Спеціальна техніка",
        "atgm_srbm_systems": "ОТРК / ТРК",
    ]

    static let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    /// День повномасштабної війни станом на сьогодні (24.02.2022 — 1-й день).
    static func warDay(_ now: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = kyiv
        let start = cal.date(from: DateComponents(year: 2022, month: 2, day: 24))!
        return (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: now)).day ?? 0) + 1
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VYSHYVKA BAR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("losses.json")
    }

    static func cached() -> LossReport? {
        guard let d = try? Data(contentsOf: cacheURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LossReport.self, from: d)
    }

    private static func save(_ r: LossReport) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(r).write(to: cacheURL, options: .atomic)
    }

    static func fetch(_ done: @escaping (LossReport?, String?) -> Void) {
        let url = URL(string: "https://russianwarship.rip/api/v2/statistics/latest")!
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var report: LossReport?, error: String?
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let data = j["data"] as? [String: Any],
               let stats = data["stats"] as? [String: Int], let day = data["day"] as? Int, let date = data["date"] as? String {
                report = LossReport(date: date, day: day, resource: data["resource"] as? String, stats: stats,
                                    increase: data["increase"] as? [String: Int] ?? [:], fetchedAt: Date())
                save(report!)
            } else {
                error = err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            DispatchQueue.main.async { done(report, error) }
        }.resume()
    }
}

// MARK: - Панель зведення

final class LossesPanel: NSPanel {
    private let content = LossesView()
    private var embroidery: Embroidery?
    private var autoClose: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = content
        content.onClose = { [weak self] in self?.dismiss() }
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    func toggle() { isVisible ? dismiss() : present() }

    func present() {
        content.report = Losses.cached()
        content.status = content.report == nil ? L.t("Завантаження зведення…", "Loading the report…") : nil
        content.rebuild()
        if let s = NSScreen.main {
            let f = s.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 40))
        }
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.22; animator().alphaValue = 1 }
        content.startMotion()
        // свіжість: не частіше ніж раз на 20 хв
        if (content.report?.fetchedAt).map({ Date().timeIntervalSince($0) > 1200 }) ?? true {
            Losses.fetch { [weak self] r, err in
                guard let self = self else { return }
                if let r = r { self.content.report = r; self.content.status = nil }
                else if self.content.report == nil { self.content.status = L.t("Немає з’єднання: ", "No connection: ") + (err ?? L.t("помилка", "error")) + L.t(". Спробуйте пізніше.", ". Try again later.") }
                else { self.content.status = L.t("Показано збережене зведення — оновити не вдалося.", "Showing the saved report — could not update.") }
                self.content.rebuild()
            }
        }
        autoClose?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoClose = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: job)
    }

    func dismiss() {
        autoClose?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; animator().alphaValue = 0 }) { [weak self] in
            self?.orderOut(nil); self?.content.stopMotion()
        }
    }
}

final class LossesView: NSView {
    var report: LossReport?
    var status: String?
    var onClose: (() -> Void)?
    private var embroidery: Embroidery?
    private var links: [(NSRect, URL)] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        layer?.backgroundColor = VB.bg.withAlphaComponent(0.97).cgColor
        layer?.borderWidth = 0.6
        layer?.borderColor = VB.cream.withAlphaComponent(0.18).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func startMotion() { embroidery?.start(fps: 30) }
    func stopMotion() { embroidery?.stop() }

    private let headerH: CGFloat = 70
    private let pad: CGFloat = 34

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.filter { $0.name == "embroidery" }.forEach { $0.removeFromSuperlayer() }
        links = []
        let W = bounds.width

        // Шапка: та сама жива вишивка з радужним тризубом, збільшена
        let scale: CGFloat = 1.9
        let bandW = W / scale
        let e = Embroidery(centerX: bandW / 2, halfWidth: bandW / 2 - 10, height: VB.barHeight)
        let holder = CALayer()
        holder.name = "embroidery"
        holder.frame = CGRect(x: 0, y: 8, width: W, height: VB.barHeight * scale)
        holder.isGeometryFlipped = true                // шари вишивки y-вгору у flipped-view
        e.root.anchorPoint = .zero
        e.root.position = .zero
        e.root.transform = CATransform3DMakeScale(scale, scale, 1)
        holder.addSublayer(e.root)
        layer?.addSublayer(holder)
        e.apply(time: 3)
        embroidery = e

        var y = headerH + 6
        let now = Date()
        let df = DateFormatter(); df.locale = L.locale; df.timeZone = Losses.kyiv
        df.dateFormat = "EEEE, d MMMM yyyy"

        // Заголовок: день війни
        let dayNum = Losses.warDay(now)
        addLabel(attr(L.lang == "en" ? [("Day ", font(26, .medium), VB.cream), ("\(dayNum)", font(58, .semibold), VB.ivory)]
                                     : [("\(dayNum)", font(58, .semibold), VB.ivory), (L.t("-й день", ""), font(26, .medium), VB.cream)]),
                 x: pad, y: y, w: W - 2 * pad)
        y += 70
        addLabel(attr([(L.t("повномасштабної війни росії проти України", "of russia’s full-scale war against Ukraine"), font(17, .medium), VB.cream)]), x: pad, y: y, w: W - 2 * pad)
        y += 24
        addLabel(attr([(df.string(from: now).capitalizedFirst, font(13, .regular), VB.label.withAlphaComponent(0.55))]),
                 x: pad, y: y, w: W - 2 * pad)
        y += 30
        stitchLine(y: y, W: W); y += 18

        guard let r = report else {
            addLabel(attr([(status ?? "", font(15, .regular), VB.label.withAlphaComponent(0.7))]), x: pad, y: y, w: W - 2 * pad)
            resizeHeight(y + 60); return
        }

        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"; iso.timeZone = Losses.kyiv
        let asOf = iso.date(from: r.date).map { d -> String in
            let f = DateFormatter(); f.locale = L.locale; f.timeZone = Losses.kyiv; f.dateFormat = "d MMMM yyyy"; return f.string(from: d)
        } ?? r.date
        addLabel(attr([(L.t("Загальні бойові втрати противника", "Total combat losses of the enemy"), font(16, .semibold), VB.ivory)]), x: pad, y: y, w: W - 2 * pad)
        y += 22
        addLabel(attr([(L.t("Зведення Генштабу ЗСУ станом на ", "Ukraine General Staff report as of ") + asOf + L.t(" · доба ", " · day ") + "\(r.day)", font(12.5, .regular), VB.label.withAlphaComponent(0.55))]),
                 x: pad, y: y, w: W - 2 * pad)
        y += 30

        // Особовий склад — головна цифра
        let p = r.stats["personnel_units"] ?? 0, pi = r.increase["personnel_units"] ?? 0
        addLabel(attr([("≈ " + num(p), font(40, .semibold), VB.ivory), ("   +" + num(pi) + L.t(" за добу", " in the last day"), font(16, .semibold), NSColor(hex: 0xE3707A))]),
                 x: pad, y: y, w: W - 2 * pad)
        y += 48
        addLabel(attr([(Losses.titles["personnel_units"] ?? "—", font(13, .medium), VB.cream)]), x: pad, y: y, w: 300)
        y += 30

        // Решта категорій — дві колонки
        let rest = Losses.order.dropFirst().filter { r.stats[$0] != nil }
        let colW = (W - 2 * pad - 36) / 2
        let rows = Int(ceil(Double(rest.count) / 2))
        for (i, k) in rest.enumerated() {
            let col = i / rows, row = i % rows
            let x = pad + CGFloat(col) * (colW + 36)
            let ry = y + CGFloat(row) * 30
            let title = Losses.titles[k] ?? k
            addLabel(attr([(title, font(13, .regular), VB.label.withAlphaComponent(0.78))]), x: x, y: ry + 3, w: colW - 140)
            var parts: [(String, NSFont, NSColor)] = [(num(r.stats[k] ?? 0), font(15.5, .semibold), VB.ivory)]
            let inc = r.increase[k] ?? 0
            parts.append((inc > 0 ? "  +\(num(inc))" : "", font(12.5, .semibold), NSColor(hex: 0xE3707A)))
            addLabel(attr(parts, align: .right), x: x + colW - 160, y: ry, w: 160)
            let dot = CALayer()
            dot.backgroundColor = VB.cream.withAlphaComponent(0.08).cgColor
            dot.frame = CGRect(x: x, y: ry + 25, width: colW, height: 0.5)
            layer?.addSublayer(dot)
        }
        y += CGFloat(rows) * 30 + 18

        // Джерела
        stitchLine(y: y, W: W); y += 14
        let upd = DateFormatter(); upd.dateFormat = "HH:mm"; upd.timeZone = Losses.kyiv
        y += addLabel(attr([(L.t("Джерело: Генеральний штаб ЗСУ. Дані — відкритий API russianwarship.rip, що агрегує щоденні зведення ГШ. Отримано о ",
                              "Source: General Staff of the Armed Forces of Ukraine. Data: the open russianwarship.rip API, which aggregates the daily reports. Fetched at ")
                          + upd.string(from: r.fetchedAt) + ".",
                        font(11.5, .regular), VB.label.withAlphaComponent(0.5))]), x: pad, y: y, w: W - 2 * pad).frame.height + 8
        if let s = status { y += addLabel(attr([(s, font(11.5, .regular), NSColor(hex: 0xE3707A))]), x: pad, y: y, w: W - 2 * pad).frame.height + 6 }
        var lx = pad
        if let src = r.resource, let u = URL(string: src) { lx = addLink(L.t("Допис Генштабу ЗСУ", "General Staff post"), u, x: lx, y: y + 4) + 26 }
        _ = addLink(L.t("mod.gov.ua — втрати ворога", "mod.gov.ua — enemy losses"), URL(string: "https://mod.gov.ua/news?tag=vtrati-protivnika")!, x: lx, y: y + 4)
        addLabel(attr([(L.t("Esc або клік — закрити", "Esc or click to close"), font(11, .regular), VB.label.withAlphaComponent(0.35))], align: .right),
                 x: W - pad - 200, y: y + 6, w: 200)
        resizeHeight(y + 44)
    }

    // MARK: helpers

    private func resizeHeight(_ h: CGFloat) {
        guard let w = window else { return }
        var f = w.frame
        let top = f.maxY
        f.size.height = h; f.origin.y = top - h
        w.setFrame(f, display: true)
    }

    private func font(_ s: CGFloat, _ wt: NSFont.Weight) -> NSFont { NSFont.monospacedDigitSystemFont(ofSize: s, weight: wt) }

    private func attr(_ parts: [(String, NSFont, NSColor)], align: NSTextAlignment = .left) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let ps = NSMutableParagraphStyle(); ps.alignment = align
        for (t, f, c) in parts { m.append(NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: ps])) }
        return m
    }

    @discardableResult
    private func addLabel(_ s: NSAttributedString, x: CGFloat, y: CGFloat, w: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithAttributedString: s)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        let h = s.boundingRect(with: NSSize(width: w, height: 400), options: [.usesLineFragmentOrigin]).height
        l.frame = NSRect(x: x, y: y, width: w, height: ceil(h) + 2)
        addSubview(l)
        return l
    }

    private func addLink(_ title: String, _ url: URL, x: CGFloat, y: CGFloat) -> CGFloat {
        let s = attr([(title, font(12.5, .medium), VB.cream)])
        let w = ceil(s.size().width) + 14
        addLabel(s, x: x, y: y, w: w)
        let line = CALayer(); line.backgroundColor = VB.red.cgColor
        line.frame = CGRect(x: x, y: y + 18, width: w, height: 0.8)
        layer?.addSublayer(line)
        links.append((NSRect(x: x, y: y - 2, width: w, height: 22), url))
        return x + w
    }

    /// Пунктирний «стібок» замість лінії-розділювача.
    private func stitchLine(y: CGFloat, W: CGFloat) {
        let s = CAShapeLayer()
        let p = CGMutablePath(); p.move(to: CGPoint(x: pad, y: y)); p.addLine(to: CGPoint(x: W - pad, y: y))
        s.path = p; s.strokeColor = VB.red.withAlphaComponent(0.6).cgColor; s.lineWidth = 1
        s.lineDashPattern = [3, 4]
        layer?.addSublayer(s)
    }

    private func num(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "; f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let (_, url) = links.first(where: { $0.0.contains(p) }) { NSWorkspace.shared.open(url); return }
        onClose?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
