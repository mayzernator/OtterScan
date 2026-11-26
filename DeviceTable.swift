// The Devices list: a plain AppKit table. SwiftUI's Table hosted a SwiftUI view in every cell and re-measured
// them all on each frame of a window resize and on every model change, which made resizing and Settings stutter.
import SwiftUI
import AppKit

// MARK: right-click menu, shared by this table (AppKit) and the Ports cards (SwiftUI)

enum MenuItem { case button(String, enabled: Bool = true, () -> Void), submenu(String, [MenuItem]), divider }

extension ScanModel {
    func menuItems(_ ip: String) -> [MenuItem] {
        guard let d = device(ip) else { return [] }
        var items: [MenuItem] = [
            .button(isFavourite(d) ? "Remove from Favourites" : "Favourite") { self.toggleFavourite(d) },
            .button("Edit Name") { self.startRename(ip) },
            .button("Reset Name", enabled: hasCustomName(d)) { self.resetName(ip) },
            .divider,
            .submenu("Open in Browser", [.button("Add New URL…") { self.newURL = "http://\(ip):"; self.addURLFor = ip }, .divider]
                + links(d).map { u in .button(u) { _ = self.openInSafari(u) } }),
            .divider,
        ]
        if !d.portsChecked || d.ports.contains(where: { $0.port == 22 }) { items.append(.button("Connect via SSH") { self.openSSH(d.ip) }) }
        items += [.button("Ping") { self.runInTerminal("ping", d.ip) }, .button("Traceroute") { self.runInTerminal("traceroute", d.ip) }, .divider,
                  .button("Copy") { self.copy(Field.allCases.map { d.text($0) }.joined(separator: "\t")) }]
        items += [("Copy IP Address", d.ip), ("Copy MAC Address", d.mac), ("Copy Hostname", d.hostname), ("Copy Vendor", d.vendor)]
            .filter { !$0.1.isEmpty && $0.1 != "?" }.map { item in .button(item.0) { self.copy(item.1) } }
        return items
    }
}

struct MenuItems: View {
    let items: [MenuItem]
    var body: some View {
        ForEach(items.indices, id: \.self) { i in
            switch items[i] {
            case .button(let title, let enabled, let run): Button(title, action: run).disabled(!enabled)
            case .submenu(let title, let sub): Menu(title) { MenuItems(items: sub) }
            case .divider: Divider()
            }
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

func nsMenuItems(_ items: [MenuItem]) -> [NSMenuItem] {
    items.map { item in
        switch item {
        case .divider: return .separator()
        case .button(let title, let enabled, let run):
            let i = ClosureMenuItem(title, run)
            i.isEnabled = enabled
            return i
        case .submenu(let title, let sub):
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = NSMenu(title: title)
            i.submenu!.autoenablesItems = false
            i.submenu!.items = nsMenuItems(sub)
            return i
        }
    }
}

// MARK: the table

// Everything besides a row's own Device that changes how its cells look.
struct Look: Equatable {
    var prefs: TablePrefs, favourites: Set<String>, renaming: String?, favouritePorts: Set<Int>
    init(_ m: ScanModel) { (prefs, favourites, renaming, favouritePorts) = (m.prefs, m.favourites, m.renaming, m.favouritePorts) }
}

final class DeviceNSTable: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }  // Edit > Copy (⌘C) on the selected row
}

struct DeviceTable: NSViewRepresentable {
    let m: ScanModel
    let rows: [Device]

    func makeCoordinator() -> DeviceTableController { DeviceTableController(m) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.build() }
    func updateNSView(_ v: NSScrollView, context: Context) { context.coordinator.update(rows) }
}

final class DeviceTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let m: ScanModel
    let table = DeviceNSTable()
    private var rows = [Device]()
    private var look: Look
    private var syncing = false  // set while we change the table ourselves, so its delegate calls don't write back to the model
    private let headerMenu = NSMenu(), rowMenu = NSMenu()

    init(_ m: ScanModel) {
        self.m = m
        look = Look(m)
    }

    func build() -> NSScrollView {
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = false
        table.rowHeight = 24
        for f in Field.allCases {
            let c = NSTableColumn(identifier: .init(f.rawValue))
            c.title = f.title
            c.minWidth = 60  // a column dragged to ~0 width crashed AppKit (2026-11-14)
            c.maxWidth = 2000
            c.width = f == .hostname ? 240 : f == .ports ? 160 : 120  // until fitColumnsOnce sizes them to the first pass
            c.sortDescriptorPrototype = NSSortDescriptor(key: f.rawValue, ascending: true)
            c.isHidden = startHidden.contains(f)
            table.addTableColumn(c)
        }
        table.autosaveName = "devices"  // AppKit keeps column widths, order and hidden columns
        table.autosaveTableColumns = true
        migrateColumns()
        for menu in [headerMenu, rowMenu] { menu.delegate = self; menu.autoenablesItems = false }
        table.headerView?.menu = headerMenu
        table.menu = rowMenu
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onCopy = { [weak self] in
            guard let self, table.selectedRow >= 0 else { return }
            let d = rows[table.selectedRow]
            m.copy(Field.allCases.map { d.text($0) }.joined(separator: "\t"))
        }
        if let o = m.sortOrder.first {
            syncing = true
            table.sortDescriptors = [NSSortDescriptor(key: o.field.rawValue, ascending: o.order == .forward)]
            syncing = false
        }
        m.attach(table)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    // Once: the columns shown under SwiftUI's Table (saved as "columns"). Setting isHidden here also autosaves it.
    private func migrateColumns() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "columnsMigrated") else { return }
        d.set(true, forKey: "columnsMigrated")
        guard let data = d.data(forKey: "columns"), let old = try? JSONDecoder().decode(TableColumnCustomization<Device>.self, from: data) else { return }
        for c in table.tableColumns {
            switch old[visibility: c.identifier.rawValue] {
            case .hidden: c.isHidden = true
            case .visible: c.isHidden = false
            default: break
            }
        }
        d.removeObject(forKey: "columns")
    }

    // Applies only what changed: inserted and removed rows, and new values in the cells already on screen.
    // Cells are updated in place, so a note being typed keeps its caret while a live scan updates the list.
    func update(_ new: [Device]) {
        let newLook = Look(m), oldLook = look
        let before = Dictionary(rows.map { ($0.ip, $0) }, uniquingKeysWith: { a, _ in a })
        let oldIDs = rows.map(\.ip), newIDs = new.map(\.ip)
        rows = new
        look = newLook
        syncing = true
        defer { syncing = false }

        if oldIDs != newIDs {
            var gone = IndexSet(), added = IndexSet()
            for change in newIDs.difference(from: oldIDs) {
                switch change {
                case .remove(let i, _, _): gone.insert(i)
                case .insert(let i, _, _): added.insert(i)
                }
            }
            table.beginUpdates()
            table.removeRows(at: gone, withAnimation: [])
            table.insertRows(at: added, withAnimation: [])
            table.endUpdates()
        }

        let all = newLook != oldLook
        var changed = IndexSet()
        for (i, d) in new.enumerated() where all || (before[d.ip].map { $0 != d } ?? false) { changed.insert(i) }
        for i in changed {
            for c in 0..<table.numberOfColumns { (table.view(atColumn: c, row: i, makeIfNecessary: false) as? DeviceCell)?.show(new[i], newLook) }
        }
        if newLook.prefs.wrapText || oldLook.prefs.wrapText { table.noteHeightOfRows(withIndexesChanged: changed) }

        let want = m.selection.flatMap { ip in new.firstIndex { $0.ip == ip } }
        if want != (table.selectedRow >= 0 ? table.selectedRow : nil) {
            if let want {
                table.selectRowIndexes([want], byExtendingSelection: false)
                table.scrollRowToVisible(want)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    // MARK: data source and delegate

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let f = Field(rawValue: column.identifier.rawValue) else { return nil }
        let cell = t.makeView(withIdentifier: column.identifier, owner: nil) as? DeviceCell ?? DeviceCell(f, m)
        cell.show(rows[row], look)
        return cell
    }

    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
        look.prefs.wrapText ? DeviceCell.rowHeight(rows[row], t.tableColumns, look, m) : 24
    }

    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !syncing, let s = t.sortDescriptors.first, let key = s.key, let f = Field(rawValue: key) else { return }
        var order = FieldOrder(f)
        order.order = s.ascending ? .forward : .reverse
        m.sortOrder = [order]
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !syncing else { return }
        let ip = table.selectedRow >= 0 ? rows[table.selectedRow].ip : nil
        if m.selection != ip { m.selection = ip }
    }

    func tableView(_ t: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? { m.title(rows[row]) }

    @objc private func doubleClicked() {
        let r = table.clickedRow, c = table.clickedColumn
        guard r >= 0, c >= 0, table.tableColumns[c].identifier.rawValue == Field.hostname.rawValue else { return }
        m.startRename(rows[r].ip)
    }

    // MARK: menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            let shown = table.tableColumns.filter { !$0.isHidden }.count
            menu.items = table.tableColumns.map { c in
                let item = ClosureMenuItem(c.title) { [weak self] in
                    c.isHidden.toggle()
                    if let self, look.prefs.wrapText { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
                }
                item.state = c.isHidden ? .off : .on
                item.isEnabled = c.isHidden || shown > 1  // always keep one column
                return item
            }
        } else {
            let r = table.clickedRow
            menu.items = r >= 0 && r < rows.count ? nsMenuItems(m.menuItems(rows[r].ip)) : []
        }
    }
}

// MARK: cells

final class DeviceCell: NSTableCellView, NSTextFieldDelegate {
    let field: Field
    unowned let m: ScanModel
    private var ip = ""
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var icon, star: NSImageView?
    private var vendor: NSTextField?
    private var dot: NSView?
    private var note, editor: EndField?
    private var editorDone = false

    static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 10)

    init(_ field: Field, _ m: ScanModel) {
        self.field = field
        self.m = m
        super.init(frame: .zero)
        identifier = .init(field.rawValue)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Still fetching")
        addSubview(spinner)
        switch field {
        case .ping:
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 4.5
            v.setAccessibilityElement(true)
            v.setAccessibilityRole(.image)
            addSubview(v)
            dot = v
        case .note:
            let f = EndField.noteBox(prompt: "")
            f.delegate = self
            addSubview(f)
            note = f
        default:
            label.font = Self.font(field)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            textField = label
        }
        if field == .hostname {
            let i = NSImageView(), s = NSImageView(image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favourite")!)
            i.contentTintColor = .controlAccentColor
            i.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            s.contentTintColor = .systemYellow
            let v = NSTextField(labelWithString: "")
            v.font = Self.caption
            v.textColor = .secondaryLabelColor
            v.lineBreakMode = .byTruncatingTail
            for x in [i, s, v] as [NSView] { addSubview(x) }
            (icon, star, vendor) = (i, s, v)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    static func font(_ f: Field) -> NSFont { codeFields.contains(f) ? mono : body }

    static func text(_ d: Device, _ f: Field, _ look: Look, _ m: ScanModel) -> String {
        switch f {
        case .hostname: return m.title(d)
        case .ports: return m.portsText(d.ports, friendly: look.prefs.friendlyPorts)
        default: return d.text(f)
        }
    }

    func show(_ d: Device, _ look: Look) {
        ip = d.ip
        let wrap = look.prefs.wrapText
        let waiting = d.wait.contains(field) && d.text(field).isEmpty
        if waiting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        label.isHidden = waiting
        label.stringValue = Self.text(d, field, look, m)
        if field == .ports, label.stringValue.hasPrefix("★") {
            let s = NSMutableAttributedString(string: label.stringValue, attributes: [.font: Self.font(field), .foregroundColor: NSColor.labelColor])
            s.addAttribute(.foregroundColor, value: NSColor.systemYellow, range: NSRange(location: 0, length: 1))
            label.attributedStringValue = s
        }
        label.maximumNumberOfLines = wrap ? 0 : 1
        label.cell?.wraps = wrap
        label.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        switch field {
        case .hostname:
            icon?.image = NSImage(systemSymbolName: symbol(d.kind), accessibilityDescription: d.kind.isEmpty ? "device" : d.kind)
            vendor?.stringValue = d.vendor
            vendor?.isHidden = waiting || d.vendor.isEmpty
            star?.isHidden = !m.isFavourite(d)
            showEditor(look.renaming == d.ip)
        case .ping:
            dot?.layer?.backgroundColor = (d.ping ? NSColor.systemGreen : .systemRed).cgColor
            dot?.setAccessibilityLabel(d.ping ? "Online" : "No ping reply")
        case .note:
            if let note {
                if note.currentEditor() == nil && note.stringValue != d.note { note.stringValue = d.note }
                note.setWraps(wrap && look.prefs.wrapNotes)
            }
        case .ports:
            toolTip = d.text(.ports)
        default: break
        }
        needsLayout = true
    }

    // The rename box sits over the name: Return or clicking away saves, Escape cancels.
    private func showEditor(_ on: Bool) {
        if !on { editor?.removeFromSuperview(); editor = nil; return }
        guard editor == nil else { return }
        let f = EndField(string: m.newName)
        f.isBordered = false  // plain text in the cell's own font, like renaming in Finder, so the row doesn't grow
        f.drawsBackground = true
        f.backgroundColor = .textBackgroundColor
        f.focusRingType = .exterior
        f.font = Self.body
        f.lineBreakMode = .byTruncatingTail
        f.delegate = self
        f.focusOnShow = true  // EndField puts the caret at the end
        editorDone = false
        editor = f
        addSubview(f)
    }

    private func finishEditing(_ save: Bool) {
        guard !editorDone, let f = editor else { return }
        editorDone = true
        let ip = ip, name = f.stringValue, m = m
        DispatchQueue.main.async {  // not inside the table's own event handling
            if save { m.rename(ip, to: name) }
            m.renaming = nil
        }
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f === note, let d = m.device(ip) else { return }
        m.setNote(d, f.stringValue)
    }
    func controlTextDidEndEditing(_ n: Notification) { if n.object as? NSTextField === editor { finishEditing(true) } }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard c === editor, sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishEditing(false)
        return true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { icon?.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .controlAccentColor }
    }

    // MARK: layout

    private static func height(_ f: NSTextField, _ w: CGFloat) -> CGFloat {
        ceil(f.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(w, 1), height: 10_000)).height)
    }
    // The name gets the room first; when it's crowded the vendor still keeps up to a third.
    private static func vendorWidth(_ vendor: String, name: CGFloat, room: CGFloat) -> CGFloat {
        guard !vendor.isEmpty else { return 0 }
        let natural = ceil((vendor as NSString).size(withAttributes: [.font: caption]).width) + 4
        return max(0, min(natural, max(room - name - 8, min(natural, room / 3))))
    }

    override func layout() {
        super.layout()
        let b = bounds
        func put(_ v: NSView, _ x: CGFloat, _ w: CGFloat, _ h: CGFloat) { v.frame = NSRect(x: x, y: ((b.height - h) / 2).rounded(), width: max(w, 0), height: h) }
        put(spinner, field == .hostname ? 26 : 0, 16, 16)
        switch field {
        case .hostname:
            put(icon!, 0, 18, 16)
            var x: CGFloat = 26
            if let editor { put(editor, x, b.width - x, 17); return }
            let starW: CGFloat = star!.isHidden ? 0 : 20
            let vw = vendor!.isHidden ? 0 : Self.vendorWidth(vendor!.stringValue, name: ceil(label.cell!.cellSize.width), room: b.width - x - starW)
            let room = b.width - x - starW - (vw > 0 ? vw + 8 : 0)
            let nameW = min(ceil(label.cell!.cellSize.width), room)
            put(label, x, nameW, Self.height(label, nameW))
            x += nameW + 8
            if vw > 0 { put(vendor!, x, vw, Self.height(vendor!, vw)); x += vw + 4 }
            if starW > 0 { put(star!, x, 16, 16) }
        case .ping: put(dot!, 2, 9, 9)
        case .note: put(note!, 0, b.width, Self.height(note!, b.width))
        default: put(label, 0, b.width, Self.height(label, b.width))
        }
    }

    // Row height with wrapping on: the tallest cell, measured the way layout() places it.
    private static let probe = NSTextField(wrappingLabelWithString: "")
    static func rowHeight(_ d: Device, _ columns: [NSTableColumn], _ look: Look, _ m: ScanModel) -> CGFloat {
        var h: CGFloat = 16
        for c in columns where !c.isHidden {
            guard let f = Field(rawValue: c.identifier.rawValue), f != .ping, f != .note || look.prefs.wrapNotes else { continue }
            var w = c.width - 6  // the cell sits inside the column's padding
            if f == .hostname {
                w -= 26 + (m.isFavourite(d) ? 20 : 0)
                let vw = vendorWidth(d.vendor, name: ceil((m.title(d) as NSString).size(withAttributes: [.font: body]).width), room: w)
                w -= vw > 0 ? vw + 8 : 0
            }
            probe.font = font(f)
            probe.stringValue = f == .note ? d.note : text(d, f, look, m)
            h = max(h, height(probe, w))
        }
        return h + 8
    }
}
