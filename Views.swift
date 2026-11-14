// OtterScan's window: toolbar, device table, port cards, details panel, status bar.
import SwiftUI
import AppKit

let buyMeACoffeeURL: URL? = nil  // set to https://buymeacoffee.com/<handle> once the account exists; nil hides the Settings button

// Sorts like the old page did: blanks stay at the bottom either way, ties fall back to IP address.
struct FieldOrder: SortComparator, Hashable {
    var field: Field
    var order = SortOrder.forward
    init(_ field: Field) { self.field = field }

    func compare(_ a: Device, _ b: Device) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        func apply(_ r: ComparisonResult) -> ComparisonResult {
            order == .forward ? r : r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : r
        }
        let byIP = cmp(ipv4(a.ip) ?? 0, ipv4(b.ip) ?? 0)
        let first: ComparisonResult
        switch field {
        case .ip: return apply(byIP)
        case .ping: first = apply(cmp(a.ping ? 1 : 0, b.ping ? 1 : 0))
        case .ports: first = apply(cmp(a.ports.count, b.ports.count))
        default:
            let x = a.text(field), y = b.text(field)
            if x.isEmpty != y.isEmpty { return x.isEmpty ? .orderedDescending : .orderedAscending }
            first = apply(x.localizedStandardCompare(y))
        }
        return first == .orderedSame ? byIP : first
    }
}

// NSTextField that puts the caret after the existing text when it gains focus (AppKit selects all by default).
// With mouseOnly it takes focus only from a click on itself: a table hands first responder to a text field in
// the selected row on selection changes, which is what used to select a row's note box.
final class EndField: NSTextField {
    var mouseOnly = false
    override func becomeFirstResponder() -> Bool {
        if mouseOnly && NSApp.currentEvent?.type != .leftMouseDown { return false }
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0) } }
        return ok
    }
}

// The note box for the table (blank) and the details panel (with a prompt).
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var prompt = ""

    func makeNSView(context: Context) -> EndField {
        let f = EndField(string: text)
        f.mouseOnly = true
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.alignment = .right
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask),
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .right; return p }()])
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: EndField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil && f.stringValue != text { f.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoteEditor
        init(_ p: NoteEditor) { parent = p }
        func controlTextDidChange(_ n: Notification) { parent.text = (n.object as? NSTextField)?.stringValue ?? parent.text }
    }
}

// A text box that sits over the name in the Device column: Return or clicking away saves, Escape cancels.
// AppKit rather than SwiftUI's TextField, which can't take focus and select its text on appearing without @FocusState.
struct NameEditor: NSViewRepresentable {
    @Binding var text: String
    var done: (Bool) -> Void  // true to save

    func makeNSView(context: Context) -> NSTextField {
        let f = EndField(string: text)
        f.isBordered = false  // plain text in the cell's own font, like renaming in Finder, so the row doesn't grow
        f.drawsBackground = true
        f.backgroundColor = .textBackgroundColor
        f.focusRingType = .exterior
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }  // EndField puts the caret at the end
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NameEditor
        private var finished = false
        init(_ p: NameEditor) { parent = p }

        private func finish(_ save: Bool) {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.parent.done(save) }  // not mid-update
        }

        func controlTextDidChange(_ n: Notification) { parent.text = (n.object as? NSTextField)?.stringValue ?? parent.text }
        func controlTextDidEndEditing(_ n: Notification) { finish(true) }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) { finish(false); return true }
            return false  // Return ends editing normally, which saves
        }
    }
}

// The details panel's title, editable in place: Return or clicking away saves a changed name, Escape reverts.
struct TitleField: NSViewRepresentable {
    var title: String
    var save: (String) -> Void

    func makeNSView(context: Context) -> EndField {
        let f = EndField(string: title)
        f.mouseOnly = true
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: EndField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil && f.stringValue != title { f.stringValue = title }  // another device was selected
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField
        init(_ p: TitleField) { parent = p }
        func controlTextDidEndEditing(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            // unchanged text isn't a rename: saving the display form ("Jos Room") would pin it as a custom name
            if f.stringValue != parent.title { let s = f.stringValue; DispatchQueue.main.async { self.parent.save(s) } }
        }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
            c.stringValue = parent.title
            c.window?.makeFirstResponder(nil)
            return true
        }
    }
}

let codeFields: Set<Field> = [.ip, .ports, .mac, .ipv6_local, .ipv6_global]
let startHidden: Set<Field> = [.manufacturer, .ipv6_local, .ipv6_global, .identification, .mdns, .smb, .smb_domain]

func symbol(_ kind: String) -> String {
    switch kind {
    case "phone": return "iphone"
    case "computer": return "laptopcomputer"
    case "tv": return "tv"
    case "speaker": return "hifispeaker"
    case "printer": return "printer"
    case "router": return "wifi.router"
    case "server": return "server.rack"
    default: return "cable.connector"  // no clue what it is: a plain network jack
    }
}

struct Spinner: View {
    var body: some View { ProgressView().controlSize(.small).accessibilityLabel("Still fetching") }
}

// Lays views out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    private func place(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points = [CGPoint](), x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += z.width + spacing
            row = max(row, z.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + row))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, place(bounds.width, subviews).points) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
}

// A menu button as wide as its current value. A Picker is as wide as its longest option, which pushed short values off-centre.
func dropdown<T: Hashable>(_ title: String, _ value: Binding<T>, _ options: [(String, T)],
                              action: (title: String, enabled: Bool, run: () -> Void)? = nil) -> some View {
    Menu {
        Picker(title, selection: value) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }.pickerStyle(.inline).labelsHidden()
        if let action { Divider(); Button(action.title, action: action.run).disabled(!action.enabled) }
    } label: {
        Text("\(title): \(options.first { $0.1 == value.wrappedValue }?.0 ?? "")").padding(.horizontal, 6)
    }
    .fixedSize()
}

// shortcut: SwiftUI's Table has no API for column widths or keyboard focus, so this finds the NSTableView behind it; replace if Table gains one.
final class TableFinder: NSView {
    var found: ((NSTableView) -> Void)?

    func look() {
        DispatchQueue.main.async { [weak self] in
            if let root = self?.window?.contentView, let t = Self.deviceTable(in: root) { self?.found?(t) }
        }
    }

    override func viewDidMoveToWindow() { look() }

    // By its column titles: the details pane's Form can be a table too.
    static func deviceTable(in v: NSView) -> NSTableView? {
        if let t = v as? NSTableView, t.tableColumns.contains(where: { c in Field.allCases.contains { $0.title == c.title } }) { return t }
        for s in v.subviews { if let t = deviceTable(in: s) { return t } }
        return nil
    }
}

struct TableAccess: NSViewRepresentable {
    let m: ScanModel

    func makeNSView(context: Context) -> TableFinder {
        let v = TableFinder()
        v.found = { [weak m] in m?.attach($0) }
        return v
    }

    func updateNSView(_ v: TableFinder, context: Context) { if !m.hasTable { v.look() } }
}

struct PreferencesView: View {
    @AppStorage("settingsTab") var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            FitScroll("GeneralPrefs") { GeneralPrefs() }.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            FitScroll("ScanPrefs") { ScanPrefs() }.tabItem { Label("Scan", systemImage: "network") }.tag("scan")
            FitScroll("NotificationPrefs") { NotificationPrefs() }.tabItem { Label("Notifications", systemImage: "bell") }.tag("notifications")
        }
        .toggleStyle(.switch)
        .navigationTitle("OtterScan")
        .frame(width: 480)
        .onAppear { applyStayOnTop() }  // Settings floats too, or the main window would cover it
    }
}

// Tab content at its full height, but never taller than the screen allows: past that it scrolls (title bar + tab bar take ~160pt).
struct FitScroll<C: View>: View {
    @ViewBuilder var content: C
    @AppStorage private var h: Double  // @AppStorage as state: swiftc here has no macro plugin; a remembered height also avoids a first-frame jump
    init(_ name: String, @ViewBuilder content: () -> C) {
        self.content = content()
        _h = AppStorage(wrappedValue: 0, "fitHeight-\(name)")
    }
    var body: some View {
        ScrollView { content.onGeometryChange(for: Double.self) { Double($0.size.height) } action: { h = $0 } }
            .frame(height: h > 0 ? min(h, (NSScreen.main?.visibleFrame.height ?? 800) - 160) : nil)
    }
}

// Stay on top: our normal windows (main and Settings) float above other apps. Async so a window that is just opening has attached.
func applyStayOnTop() {
    DispatchQueue.main.async {
        let level: NSWindow.Level = UserDefaults.standard.bool(forKey: "stayOnTop") ? .floating : .normal
        for w in NSApp.windows where w.level == .normal || w.level == .floating { w.level = level }
        NSApp.keyWindow?.orderFront(nil)  // keep the window in use (Settings, when toggling) above the other
    }
}

struct GeneralPrefs: View {
    @AppStorage("defaultLive") var live = false
    @AppStorage("defaultMode") var mode = "common"
    @AppStorage("customPorts") var customPorts = ""  // read when the next scan starts
    var portsProblem: String? { do { _ = try parsePorts(customPorts); return nil } catch { return error.localizedDescription } }
    @AppStorage("livePause") var pause = 5.0
    @AppStorage("autoDetails") var autoDetails = true
    @AppStorage("liveAtLaunch") var liveAtLaunch = true
    @AppStorage("stayOnTop") var stayOnTop = false
    @AppStorage("autoUpdate") var autoUpdate = true
    @AppStorage("wrapText") var wrapText = false
    @AppStorage("friendlyPorts") var friendlyPorts = false
    let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OtterScan").font(.headline)
                        Text("Finds and watches the devices on your network").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            Section("When OtterScan Opens") {
                Toggle(isOn: $liveAtLaunch) {
                    Text("Start scanning right away")
                    Text("Begins a scan as soon as the window opens.")
                }
                Picker(selection: $live) { Text("Scan").tag(false); Text("Live Scan").tag(true) } label: {
                    Text("Scan type")
                    Text("Live Scan keeps rescanning so you see devices come and go.")
                }
                Picker(selection: $pause) { ForEach([5.0, 10, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) } } label: {
                    Text("Live Scan checks every")
                    Text("Shorter notices changes sooner but makes more network traffic.")
                }
            }
            Section("Device Table") {
                Picker(selection: $mode) { Text("Off").tag("off"); Text("Common").tag("common"); Text("Custom").tag("custom"); Text("All (slow)").tag("all") } label: {
                    Text("Port check")
                    Text("Which ports to check on each device. Changing it rescans.")
                }
                if mode == "custom" {
                    TextField("Custom ports", text: $customPorts, prompt: Text("22,80,443,8000-8100"))
                    if let e = portsProblem { Text(e).foregroundStyle(.red).font(.caption) }
                }
                Toggle(isOn: $autoDetails) {
                    Text("Open details on select")
                    Text("Shows the details panel when you pick a device.")
                }
                Toggle(isOn: $wrapText) {
                    Text("Wrap text")
                    Text("Long names and port lists use more lines instead of being cut off.")
                }
                Toggle(isOn: $friendlyPorts) {
                    Text("Friendly port names")
                    Text("Shows SSH 22 instead of just 22.")
                }
            }
            Section("Window") {
                Toggle(isOn: $stayOnTop) {
                    Text("Keep on top")
                    Text("OtterScan stays above other apps' windows.")
                }.onChange(of: stayOnTop) { applyStayOnTop() }
            }
            Section("Updates") {
                Toggle(isOn: $autoUpdate) {
                    Text("Check for updates automatically")
                    Text("Looks once a day at launch and only speaks up when there's a new version.")
                }
                LabeledContent("Version") {
                    HStack {
                        Text("\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))").foregroundStyle(.secondary)
                        Button("Check Now") { checkForUpdates() }
                    }
                }
                if let buyMeACoffeeURL {
                    Link(destination: buyMeACoffeeURL) { Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill") }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // the outer ScrollView scrolls; the form keeps its full height so the window sizes to it
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct NotificationPrefs: View {
    @AppStorage("notifyNewJoin") var newJoin = false
    @AppStorage("notifyNewLeave") var newLeave = false
    @AppStorage("notifyKnownJoin") var knownJoin = false
    @AppStorage("notifyKnownLeave") var knownLeave = false

    var body: some View {
        Form {
            Section("Known Devices") {
                Toggle(isOn: $knownJoin) { Text("Joins the network"); Text("A device you've seen before comes back.") }
                Toggle(isOn: $knownLeave) { Text("Leaves the network"); Text("A device you've seen before stops answering.") }
            }
            Section("New Devices") {
                Toggle(isOn: $newJoin) { Text("Joins the network"); Text("A device OtterScan has never seen shows up.") }
                Toggle(isOn: $newLeave) { Text("Leaves the network"); Text("A device that first showed up since OtterScan opened goes away.") }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // the outer ScrollView scrolls; the form keeps its full height so the window sizes to it
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: [newJoin, newLeave, knownJoin, knownLeave]) {
            if [newJoin, newLeave, knownJoin, knownLeave].contains(true) { askToNotify() }  // permission is asked for here, not at launch
        }
    }
}

struct ScanPrefs: View {
    @AppStorage("scanInterface") var name = ""
    @AppStorage("scanTargets") var targets = ""  // typed IPs/CIDRs; overrides the interface and range below
    var targetsProblem: String? {
        if targets.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        do { _ = try parseNets(targets); return nil } catch { return error.localizedDescription }
    }
    @AppStorage("scanRanges") var rangesRaw = ""  // From/To per network, see savedRange
    @AppStorage("savedRanges") var savedRaw = ""  // "from - to" entries, one per line (no @State: swiftc here has no macro plugin)
    var savedAll: [String] { savedRaw.split(separator: "\n").map(String.init) }
    // only the saved ranges that fit this network, so another subnet's entries don't show up (or get applied) here
    var saved: [String] {
        guard let net else { return savedAll }
        let all = Net(from: net.base, to: net.last)
        return savedAll.filter { e in let p = e.components(separatedBy: " - "); return p.count == 2 && p.allSatisfy { ipv4($0).map(all.contains) ?? false } }
    }
    var range: (from: String, to: String) { net.flatMap { savedRange($0, in: rangesRaw) } ?? (firstHost, lastHost) }
    var from: String { range.from }
    var to: String { range.to }
    func setRange(_ f: String, _ t: String) { if let net { rangesRaw = settingRange(net, f, t, in: rangesRaw) } }
    var fromField: Binding<String> { Binding(get: { from }, set: { setRange($0, to) }) }
    var toField: Binding<String> { Binding(get: { to }, set: { setRange(from, $0) }) }
    // Real LAN interfaces only: no loopback, link-local or public addresses
    let names = friendlyInterfaceNames()
    let ifaces = interfaces().filter { isPrivate($0.ip) && ipv4($0.ip).hasPrefix("127.") == false && ipv4($0.ip).hasPrefix("169.254.") == false }

    var chosen: Iface? { ifaces.first { $0.name == name } ?? (try? localNet()).flatMap { n in ifaces.first { Net($0.ip, $0.mask.nonzeroBitCount).base == n.base } } }
    var net: Net? { chosen.map { Net($0.ip, $0.mask.nonzeroBitCount) } }
    var problem: String? {
        guard let net else { return nil }
        do { _ = try checkedNet(try customRange(net, from, to)); return nil } catch { return error.localizedDescription }
    }

    var current: String { "\(from.trimmingCharacters(in: .whitespaces)) - \(to.trimmingCharacters(in: .whitespaces))" }
    var selected: Binding<String> {
        Binding(get: { saved.contains(current) ? current : "" }, set: { s in
            let p = s.components(separatedBy: " - ")
            if p.count == 2 { setRange(p[0], p[1]) }
        })
    }
    var firstHost: String { net.map { ipv4($0.hosts.first ?? $0.base) } ?? "" }
    var lastHost: String { net.map { ipv4($0.hosts.last ?? $0.last) } ?? "" }
    func fill() { setRange(firstHost, lastHost) }  // real values, not placeholders, so typing edits them
    func store(_ list: [String]) { savedRaw = (savedAll.filter { !saved.contains($0) } + list).joined(separator: "\n") }

    var body: some View {
        Form {
            Section("Network") {
                Picker("Interface", selection: $name) {
                    Text("Automatic").tag("")
                    ForEach(ifaces, id: \.name) { Text("\($0.name)" + (names[$0.name].map { " – \($0)" } ?? "") + " (\(ipv4($0.ip)))").tag($0.name) }
                }
                if let i = chosen, let n = net {
                    LabeledContent("MAC", value: i.mac)
                    LabeledContent("IP / Mask", value: "\(ipv4(i.ip)) / \(ipv4(i.mask))")
                    LabeledContent("Range", value: n.description)
                }
            }
            Section("Scan Targets") {
                TextField("IPs / CIDRs", text: $targets, prompt: Text("192.168.1.10, 192.168.2.0/24"))
                Text(targetsProblem ?? "Optional. When filled in, only these private addresses are scanned instead of the network below.")
                    .foregroundStyle(targetsProblem == nil ? Color.secondary : Color.red).font(.caption)
            }
            Section("Scan Range") {
                HStack {
                    Picker("Saved ranges", selection: selected) {
                        Text(saved.isEmpty ? "None saved" : "Choose…").tag("")
                        ForEach(saved, id: \.self) { Text($0).tag($0) }
                    }
                    Button { store(saved.filter { $0 != selected.wrappedValue }) } label: { Image(systemName: "trash") }
                        .disabled(selected.wrappedValue.isEmpty).help("Delete the selected saved range")
                }
                TextField("From", text: fromField)
                TextField("To", text: toField)
                HStack {
                    if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    Button("Save") { store(saved + [current]) }
                        .disabled(problem != nil || from.isEmpty || to.isEmpty || saved.contains(current))
                        .help("Keep this range in the Saved ranges list")
                    Button("Reset") { fill() }.disabled(from == firstHost && to == lastHost)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // the outer ScrollView scrolls; the form keeps its full height so the window sizes to it
        .fixedSize(horizontal: false, vertical: true)
    }
}

let KINDS_SHOWN: [(String, String?)] = [
    ("All", nil), ("Computers", "computer"), ("Phones", "phone"), ("TVs", "tv"), ("Speakers", "speaker"),
    ("Printers", "printer"), ("Routers", "router"), ("Servers", "server"), ("Unknown", "")]

struct PortChips: View {
    let ports: [Port]
    var body: some View {
        FlowLayout {
            ForEach(ports) { p in
                HStack(spacing: 6) {
                    if p.name != "Unknown" { Text(p.name) }
                    Text(String(p.port)).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(.tint)
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct Reactions: ViewModifier {
    @ObservedObject var m: ScanModel

    func body(content: Content) -> some View {
        content
            .onChange(of: m.sortOrder) { m.pin = false }
            .onChange(of: m.selection) { old, new in
                // only on the first selection, so arrowing through the list doesn't reopen a pane you closed
                if new == nil { m.showDetails = false } else if old == nil && UserDefaults.standard.bool(forKey: "autoDetails") { m.showDetails = true }
            }
            .onChange(of: m.view) { _, v in
                if v == .ports && m.mode == .off { m.mode = .common }
                if v == .exposed && m.exposure == nil { m.checkExposure() }
            }
            .onChange(of: m.mode) { m.portLevelChanged() }
            .onAppear {
                m.loadPublicInfo()
                m.installArrowKeys()
                applyStayOnTop()
                if UserDefaults.standard.bool(forKey: "liveAtLaunch") && !m.started { m.liveScan() }
            }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: ScanModel
    @AppStorage("defaultMode") var portCheck = "common"
    @AppStorage("wrapText") var wrapText = false
    @AppStorage("friendlyPorts") var friendlyPorts = false
    var shown: [Device] {
        let q = m.search.trimmingCharacters(in: .whitespaces).lowercased()
        var r = m.rows.filter { d in
            m.filters.matches(d, favourite: m.isFavourite(d))
                && (q.isEmpty || d.vendor.lowercased().contains(q) || Field.allCases.contains { $0 != .ping && d.text($0).lowercased().contains(q) })
        }
        r.sort(using: m.sortOrder)
        return m.pin ? r.filter { m.mine.contains($0.ip) } + r.filter { !m.mine.contains($0.ip) } : r
    }

    var addURLShown: Binding<Bool> {
        Binding(get: { m.addURLFor != nil }, set: { if !$0 { m.addURLFor = nil } })
    }

    // Split in two: one long chain of modifiers is more than the type checker will take.
    var body: some View {
        chrome.modifier(Reactions(m: m))
            .onChange(of: portCheck) { m.mode = Mode(rawValue: portCheck) ?? .common }  // the Settings picker applies live (Reactions rescans)
    }

    var chrome: some View {
        let rows = shown
        return Group {
            switch m.view {
            case .devices: table(rows)
            case .ports: cards(rows.filter { !$0.ports.isEmpty })
            case .exposed: exposedView
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if m.view != .exposed { filterBar } }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar(rows.count) }
        .inspector(isPresented: $m.showDetails) {
            details.inspectorColumnWidth(min: 280, ideal: 330, max: 460)
        }
        .toolbar { toolbar }
        .onReceive(NotificationCenter.default.publisher(for: .printList)) { _ in
            printList(m.view == .ports ? shown.filter { !$0.ports.isEmpty } : shown)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDevice)) { n in
            m.view = .devices
            m.selection = n.object as? String
            m.showDetails = true
        }
        .searchable(text: $m.search, prompt: "Search")
        .navigationTitle("OtterScan")
        .navigationSubtitle(m.range)
        .alert("Add New URL", isPresented: addURLShown) {
            TextField("URL", text: $m.newURL)
            Button("Open") { if let ip = m.addURLFor { m.addURL(m.newURL, for: ip) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Scan type", selection: $m.live) {
                    Label("Live Scan", systemImage: "dot.radiowaves.left.and.right").tag(true)
                    Label("Scan", systemImage: "magnifyingglass").tag(false)
                }.pickerStyle(.inline)
            } label: {
                Label(m.running ? "Stop" : m.live ? "Live Scan" : "Scan",
                      systemImage: m.running ? "stop.fill" : m.live ? "dot.radiowaves.left.and.right" : "magnifyingglass")
            } primaryAction: { m.toggle() }
            Button { m.start() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                .disabled(m.running || m.live || !m.started).help("Scan again")
            Picker("View", selection: $m.view) {
                Text("Devices").tag(ViewKind.devices)
                Text("Ports").tag(ViewKind.ports)
                // Public tab hidden for now (the view and Shodan lookup stay in place): Text("Public").tag(ViewKind.exposed)
            }.pickerStyle(.segmented)
        }
        ToolbarItem {
            Button { if let ip = m.selection { m.startRename(ip) } } label: { Label("Edit Name", systemImage: "pencil") }
                .keyboardShortcut("r").disabled(m.selection == nil).help("Edit name (⌘R)")
        }
        ToolbarItem {
            Button { m.showDetails.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                .help("Show or hide device details")
        }
    }

    // MARK: filters

    var filterBar: some View {
        var ports = Dictionary(m.rows.flatMap(\.ports).map { ($0.port, $0.label) }, uniquingKeysWith: { a, _ in a })
        if case .port(let p) = m.filters.port, ports[p] == nil { ports[p] = Port(port: p, name: service(p)).label }  // keep the choice through a rescan
        let portChoices: [(String, PortFilter)] = [("All", .any), ("Any Open", .open), ("None Open", .closed)]
            + ports.sorted { $0.key < $1.key }.map { ($0.value, .port($0.key)) }
        let vendors = Set(m.rows.map(\.vendor)).union(m.filters.vendor.map { [$0] } ?? []).filter { !$0.isEmpty }.sorted()
        let vendorChoices: [(String, String?)] = [("All", nil)] + vendors.map { ($0, $0) }
        let pingChoices: [(String, Bool?)] = [("All", nil), ("Online", true), ("No Reply", false)]

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                dropdown("Type", $m.filters.kind, KINDS_SHOWN)
                dropdown("Vendor", $m.filters.vendor, vendorChoices)
                dropdown("Ping", $m.filters.ping, pingChoices)
                dropdown("Ports", $m.filters.port, portChoices,
                         action: ("Scan Every Port on Selected Device", m.selection.map { !m.scanningPorts.contains($0) } ?? false,
                                  { if let ip = m.selection { m.scanEveryPort(ip) } }))
                dropdown("Show", $m.filters.favourites, [("All", false), ("Favourites", true)])
                if m.filters != Filters() { Button("Clear") { m.filters = Filters() } }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
    }

    // MARK: public ports

    var exposedView: some View {
        Form {
            Section("Public Address") {
                LabeledContent("IP Address") { Text(m.me["query"] ?? "Unknown") }
                if let isp = m.me["isp"] { LabeledContent("ISP") { Text(isp) } }
                if let country = m.me["country"] { LabeledContent("Country") { Text(country) } }
                if let names = m.exposure?.hostnames, !names.isEmpty {
                    LabeledContent("Hostnames") { Text(names.joined(separator: ", ")).multilineTextAlignment(.trailing) }
                }
            }
            Section {
                if m.checkingExposure {
                    LabeledContent("Checking") { Spinner() }
                } else if let error = m.exposureError {
                    Text(error).foregroundStyle(.secondary)
                } else if let ports = m.exposure?.ports {
                    if ports.isEmpty { Text("Shodan has no open ports on record for this address.").foregroundStyle(.secondary) }
                    ForEach(ports, id: \.self) { p in
                        let name = service(p)
                        LabeledContent(name == "Unknown" ? "Port \(p)" : name) {
                            Text(String(p)).font(.system(.callout, design: .monospaced))
                        }
                    }
                }
            } header: {
                Text("Open to the Internet")
            } footer: {
                Text("From Shodan's most recent crawl of your public address, so it can be out of date. Opening this tab sends that address to Shodan.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Check Again") { m.checkExposure() }.disabled(m.checkingExposure)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    // MARK: devices

    func table(_ rows: [Device]) -> some View {
        Table(of: Device.self, selection: $m.selection, sortOrder: $m.sortOrder, columnCustomization: m.columnsBinding) {
            TableColumnForEach(Field.allCases) { f in
                // min ≈ the "MAC" header plus padding and sort arrow; a column dragged to ~0 width crashed AppKit (2026-11-14). SwiftUI keeps this, unlike NSTableColumn.minWidth.
                TableColumn(f.title, sortUsing: FieldOrder(f)) { d in cell(d, f) }.width(min: 60)
                    .customizationID(f.rawValue)
                    .defaultVisibility(startHidden.contains(f) ? .hidden : .automatic)
            }
        } rows: {
            ForEach(rows) { TableRow($0) }
        }
        .contextMenu(forSelectionType: String.self) { ids in menu(ids) }
        .background(TableAccess(m: m))
    }

    // The table's note box is blank; the details panel passes a prompt.
    func noteField(_ d: Device, prompt: String = "") -> some View {
        NoteEditor(text: Binding(get: { m.device(d.ip)?.note ?? "" }, set: { m.setNote(d, $0) }), prompt: prompt)
    }

    @ViewBuilder func cell(_ d: Device, _ f: Field) -> some View {
        if f == .hostname && m.renaming == d.ip {
            HStack(spacing: 8) {  // same icon and spacing as the normal cell, so the box sits exactly over the name
                Image(systemName: symbol(d.kind)).foregroundStyle(.tint).frame(width: 18).accessibilityHidden(true)
                NameEditor(text: $m.newName) { save in
                    if save { m.rename(d.ip, to: m.newName) }
                    m.renaming = nil
                }
                .frame(height: 16)
            }
        } else if f == .hostname {
            HStack(spacing: 8) {
                Image(systemName: symbol(d.kind)).foregroundStyle(.tint).frame(width: 18).accessibilityLabel(d.kind.isEmpty ? "device" : d.kind)
                if d.wait.contains(.hostname) && d.hostname.isEmpty {
                    Spinner()
                } else {
                    Text(m.title(d)).lineLimit(wrapText ? nil : 1)
                    if !d.vendor.isEmpty { Text(d.vendor).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if m.isFavourite(d) { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favourite") }
            }
            .contentShape(Rectangle()).onTapGesture(count: 2) { m.startRename(d.ip) }
        } else if f == .note {
            noteField(d)
        } else if d.wait.contains(f) && d.text(f).isEmpty {
            Spinner()
        } else if f == .ping {
            Circle().fill(d.ping ? Color.green : Color.red).frame(width: 9, height: 9)
                .accessibilityLabel(d.ping ? "Online" : "No ping reply")
        } else if f == .ports {
            Text(d.ports.map { friendlyPorts ? $0.label : String($0.port) }.joined(separator: ", ")).font(.system(.callout, design: .monospaced))
                .lineLimit(wrapText ? nil : 1).help(d.text(.ports))
        } else {
            Text(d.text(f)).font(codeFields.contains(f) ? .system(.callout, design: .monospaced) : .body).lineLimit(wrapText ? nil : 1)
        }
    }

    // One lazy stack per column, so cards sit directly under each other whatever their heights.
    func cards(_ rows: [Device]) -> some View {
        GeometryReader { geo in
            let n = max(1, Int((geo.size.width - 20) / 332))  // 320 wide + 12 spacing, inside 16 padding
            let columns = cardColumns(rows, n)
            let _ = { m.cardGrid = columns.map { $0.map(\.ip) } }()  // for arrow-key navigation (not published, so safe in body)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns, id: \.first?.ip) { column in
                            LazyVStack(spacing: 12) { ForEach(column) { card($0).id($0.ip) } }
                        }
                    }.padding(16)
                }
                .onChange(of: m.selection) { _, ip in if let ip { proxy.scrollTo(ip) } }
            }
        }
    }

    // shortcut: balances by port count, not measured height, so columns can end a little unevenly; fine for a list this size.
    func cardColumns(_ rows: [Device], _ n: Int) -> [[Device]] {
        var columns = [[Device]](repeating: [], count: n), weight = [Int](repeating: 0, count: n)
        for d in rows {
            let c = weight.indices.min { weight[$0] < weight[$1] } ?? 0
            columns[c].append(d)
            weight[c] += 4 + d.ports.count
        }
        return columns.filter { !$0.isEmpty }
    }

    func card(_ d: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.title(d)).font(.headline).textSelection(.enabled)
                    if m.isFavourite(d) { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favourite") }
                }
                Text([d.ip, d.vendor, "\(d.ports.count) open port\(d.ports.count == 1 ? "" : "s")"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            PortChips(ports: d.ports)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(m.selection == d.ip ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(m.selection == d.ip ? Color.accentColor : Color.secondary.opacity(0.3)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { m.selection = d.ip }
        .contextMenu { menu([d.ip]) }
    }

    var statusText: String {
        if m.view == .exposed { return m.checkingExposure ? "Checking public ports..." : m.exposureError ?? "Public ports as last seen by Shodan" }
        if !m.started {
            return m.view == .ports ? "Press the scan button to check this network for open ports." : "Press the scan button to find devices on this network."
        }
        if m.view == .ports && m.message == "Scan complete" && !m.rows.contains(where: { !$0.ports.isEmpty }) { return "No open ports found" }
        return m.message
    }

    func statusBar(_ shownCount: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if m.running {
                    if let total = m.total, !m.live {
                        ProgressView(value: Double(m.done), total: Double(max(total, 1))).frame(width: 110)
                    } else {
                        ProgressView().progressViewStyle(.linear).frame(width: 110)
                    }
                }
                Text(statusText)
                Spacer()
                Text("Devices seen: \(m.rows.count)" + (shownCount != m.rows.count ? " (\(shownCount) shown)" : ""))
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    // MARK: right-click menu

    @ViewBuilder func menu(_ ids: Set<String>) -> some View {
        if let ip = ids.first, let d = m.device(ip) {
            Button(m.isFavourite(d) ? "Remove from Favourites" : "Favourite") { m.toggleFavourite(d) }
            Divider()
            Menu("Open in Browser") {
                Button("Add New URL…") { m.newURL = "http://\(ip):"; m.addURLFor = ip }
                Divider()
                ForEach(d.webURLs + (m.urls[ip] ?? []), id: \.self) { u in
                    Button(u) { m.openInSafari(u) }
                }
            }
            Divider()
            Button("Copy") { m.copy(Field.allCases.map { d.text($0) }.joined(separator: "\t")) }
            ForEach([("Copy IP Address", d.ip), ("Copy MAC Address", d.mac), ("Copy Hostname", d.hostname), ("Copy Vendor", d.vendor)]
                .filter { !$0.1.isEmpty && $0.1 != "?" }, id: \.0) { item in
                Button(item.0) { m.copy(item.1) }
            }
        }
    }

    // MARK: details panel

    @ViewBuilder var details: some View {
        if let d = m.device(m.selection) {
            let busy = m.scanningPorts.contains(d.ip)
            Form {
                Section {
                    TitleField(title: m.title(d)) { m.rename(d.ip, to: $0) }
                        .frame(height: 24).help("Click to rename")
                    row("Hostname", d.host, .host, d)
                    row("Manufacturer", d.vendor, nil, d)
                    row("Model", d.model, .model, d)
                    LabeledContent("Note") {
                        noteField(d, prompt: "Add a note")
                    }
                    LabeledContent("IPv4 Address") {
                        Button(d.ip) {
                            let https = d.ports.contains { $0.port == 443 } && !d.ports.contains { $0.port == 80 }
                            m.openInSafari("\(https ? "https" : "http")://\(d.ip)/")
                        }.buttonStyle(.link).help("Open in Safari")
                    }
                    LabeledContent("Ping") {
                        Label(d.ping ? "Online" : "No reply", systemImage: "circle.fill").foregroundStyle(d.ping ? .green : .red)
                    }
                    // on its own line and left-aligned: as a right-hand value, its left edge moved with the width of the tags
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Open Ports")
                        if d.wait.contains(.ports) && d.ports.isEmpty {
                            Spinner()
                        } else if !d.ports.isEmpty {
                            PortChips(ports: d.ports)
                        } else {
                            Text(d.portsChecked ? "None found" : "Not checked").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    row("MAC Address", d.mac == "?" ? "" : d.mac, nil, d)
                    row("IPv6 Local", d.ipv6Local, nil, d)
                    row("IPv6 Global", d.ipv6Global, nil, d)
                    row("Identification", d.identification, .identification, d)
                    row("mDNS Name", d.mdns, .mdns, d)
                    row("SMB Name", d.smb, .smb, d)
                    row("SMB Domain", d.smbDomain, .smb_domain, d)
                    row("DNS Name", d.dns, .dns, d)
                }
                Section {
                    row("ISP", m.me["isp"] ?? "", nil, d)
                    row("Country", m.me["country"] ?? "", nil, d)
                    row("Public IPv4", m.me["query"] ?? "", nil, d)
                }
                Section {
                    Button(busy ? "Scanning..." : "Scan Every Port") { m.scanEveryPort(d.ip) }.disabled(busy)
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
        } else {
            Text("Select a device to see its details.").foregroundStyle(.secondary).padding()
        }
    }

    // Blank values are left out, unless that value is still being looked up.
    @ViewBuilder func row(_ title: String, _ value: String, _ field: Field?, _ d: Device) -> some View {
        if let field, d.wait.contains(field), value.isEmpty {
            LabeledContent(title) { Spinner() }
        } else if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Notification.Name {
    static let printList = Notification.Name("printList")
    static let openDevice = Notification.Name("openDevice")  // object: the device's IP
}

// Prints the rows on screen (after search and filters) as a plain monospaced table, landscape.
func printList(_ rows: [Device]) {
    let cols: [(String, (Device) -> String)] = [("Device", { $0.hostname }), ("IPv4", { $0.ip }), ("MAC", { $0.mac }),
                                                ("Vendor", { $0.vendor }), ("Open Ports", { $0.text(.ports) })]
    let table = [cols.map(\.0)] + rows.map { d in cols.map { $0.1(d) } }
    let widths = cols.indices.map { c in table.map { $0[c].count }.max()! + 2 }
    let text = table.map { row in
        row.enumerated().map { i, s in i == cols.count - 1 ? s : s.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined()
    }.joined(separator: "\n")

    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.orientation = .landscape
    info.isVerticallyCentered = false
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width - info.leftMargin - info.rightMargin, height: 0))
    view.font = .monospacedSystemFont(ofSize: 8, weight: .regular)
    view.string = text
    view.layoutManager!.ensureLayout(for: view.textContainer!)
    view.frame.size.height = view.layoutManager!.usedRect(for: view.textContainer!).height + 20
    NSPrintOperation(view: view, printInfo: info).run()
}

