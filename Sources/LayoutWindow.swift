import AppKit

/// «Елементи панелі»: перетягуванням змінюється порядок, галочкою — показувати чи ні.
/// Рядки над «вишивкою» стоять ліворуч, під нею — праворуч. Зміни видно на Touch Bar одразу.
final class LayoutWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row: Equatable { case slot(Slot), center }
    private var rows: [Row] = []
    private var hidden: Set<Slot> = []
    private let table = NSTableView()
    private static let dragType = NSPasteboard.PasteboardType("ua.vyshyvka.bar.row")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = VB.bg
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let v = NSView(frame: contentRect(forFrameRect: frame))
        contentView = v
        let title = NSTextField(labelWithString: L.t("Елементи панелі", "Bar items"))
        title.font = .systemFont(ofSize: 22, weight: .semibold); title.textColor = VB.ivory
        let hint = NSTextField(wrappingLabelWithString: L.t(
            "Перетягуйте рядки, щоб змінити порядок. Над вишивкою — ліва частина Touch Bar, під нею — права. Зніміть галочку, щоб сховати елемент.",
            "Drag rows to reorder. Items above the embroidery sit on the left of the Touch Bar, items below it on the right. Uncheck to hide an item."))
        hint.font = .systemFont(ofSize: 12); hint.textColor = VB.cream

        let col = NSTableColumn(identifier: .init("c")); col.width = 380
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = false

        let reset = NSButton(title: L.t("Типово", "Defaults"), target: self, action: #selector(resetLayout))
        let done = NSButton(title: L.t("Готово", "Done"), target: self, action: #selector(close))
        done.keyEquivalent = "\r"; reset.bezelStyle = .rounded; done.bezelStyle = .rounded

        for x in [title, hint, scroll, reset, done] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32), title.topAnchor.constraint(equalTo: v.topAnchor, constant: 44),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor), hint.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -32),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -16),
            reset.leadingAnchor.constraint(equalTo: title.leadingAnchor), reset.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -22),
            done.trailingAnchor.constraint(equalTo: hint.trailingAnchor), done.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -22),
        ])
        load()
    }

    private func load() {
        rows = BarLayout.left.map { .slot($0) } + [.center] + BarLayout.right.map { .slot($0) }
        hidden = BarLayout.hidden
        table.reloadData()
    }

    private func save() {
        guard let c = rows.firstIndex(of: .center) else { return }
        func slots(_ r: ArraySlice<Row>) -> [Slot] { r.compactMap { if case .slot(let s) = $0 { return s } else { return nil } } }
        BarLayout.save(left: slots(rows[..<c]), right: slots(rows[(c + 1)...]), hidden: hidden)
    }

    func show() {
        load()
        if !isVisible { center() }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    @objc private func resetLayout() { BarLayout.reset(); load() }
    override func cancelOperation(_ sender: Any?) { close() }

    // MARK: таблиця

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row i: Int) -> NSView? {
        let cell = NSView()
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.tag = i
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13.5)
        let grip = NSTextField(labelWithString: "≡")
        grip.font = .systemFont(ofSize: 17); grip.textColor = VB.cream.withAlphaComponent(0.6)
        switch rows[i] {
        case .slot(let s):
            label.stringValue = s.title; label.textColor = hidden.contains(s) ? VB.label.withAlphaComponent(0.4) : VB.label
            box.state = hidden.contains(s) ? .off : .on
        case .center:
            label.stringValue = L.t("— Вишивка з тризубом (центр) —", "— Embroidery with trident (center) —")
            label.textColor = VB.red.blended(withFraction: 0.35, of: VB.ivory) ?? VB.red
            label.font = .systemFont(ofSize: 13.5, weight: .medium)
            box.state = BarLayout.embroideryHidden ? .off : .on
            grip.isHidden = true                 // центр не рухається, рухаються елементи навколо
        }
        for x in [box, label, grip] { x.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(x) }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            grip.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 7
        cell.layer?.backgroundColor = (rows[i] == .center ? VB.red.withAlphaComponent(0.10) : VB.ivory.withAlphaComponent(0.05)).cgColor
        return cell
    }

    @objc private func toggled(_ b: NSButton) {
        guard b.tag < rows.count else { return }
        switch rows[b.tag] {
        case .slot(let s): if b.state == .on { hidden.remove(s) } else { hidden.insert(s) }
        case .center: BarLayout.embroideryHidden = b.state == .off
        }
        save()
        table.reloadData(forRowIndexes: [b.tag], columnIndexes: [0])
    }

    func tableView(_: NSTableView, pasteboardWriterForRow i: Int) -> NSPasteboardWriting? {
        guard rows[i] != .center else { return nil }
        let item = NSPasteboardItem(); item.setString(String(i), forType: Self.dragType)
        return item
    }

    func tableView(_: NSTableView, validateDrop _: NSDraggingInfo, proposedRow _: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        op == .above ? .move : []
    }

    func tableView(_: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation _: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(s), from < rows.count else { return false }
        let item = rows.remove(at: from)
        rows.insert(item, at: from < row ? row - 1 : row)
        save()
        table.reloadData()
        return true
    }
}
