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

// A text box that sits over the name in the Device column: Return or clicking away saves, Escape cancels.
// AppKit rather than SwiftUI's TextField, which can't take focus and select its text on appearing without @FocusState.
struct NameEditor: NSViewRepresentable {
    @Binding var text: String
    var done: (Bool) -> Void  // true to save

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.isBordered = false  // plain text in the cell's own font, like renaming in Finder, so the row doesn't grow
        f.drawsBackground = true
        f.backgroundColor = .textBackgroundColor
        f.focusRingType = .exterior
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
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
    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralPrefs().tabItem { Label("General", systemImage: "gearshape") }
                ScanPrefs().tabItem { Label("Scan", systemImage: "network") }
                NotificationPrefs().tabItem { Label("Notifications", systemImage: "bell") }
            }
            HStack {
                Spacer()
                Button("OK") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .navigationTitle("OtterScan")
        .frame(width: 460)
        .onAppear { applyStayOnTop() }  // Settings floats too, or the main window would cover it
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
    @AppStorage("livePause") var pause = 5.0
    @AppStorage("autoDetails") var autoDetails = true
    @AppStorage("liveAtLaunch") var liveAtLaunch = true
    @AppStorage("stayOnTop") var stayOnTop = false
    @AppStorage("wrapText") var wrapText = false

    var body: some View {
        Form {
            Toggle("Start a Live Scan when OtterScan opens", isOn: $liveAtLaunch)
            Picker("Scan type at launch", selection: $live) {
                Text("Scan").tag(false)
                Text("Live Scan").tag(true)
            }
            Picker("Port check at launch", selection: $mode) {
                Text("Off").tag("off")
                Text("Common").tag("common")
                Text("All (slow)").tag("all")
            }
            Picker("Live Scan checks every", selection: $pause) {
                ForEach([5.0, 10, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
            Toggle("Open details when a device is selected", isOn: $autoDetails)
            Toggle("Wrap text in the device table", isOn: $wrapText)
            Toggle("Keep OtterScan on top of other windows", isOn: $stayOnTop)
                .onChange(of: stayOnTop) { applyStayOnTop() }
            if let buyMeACoffeeURL {
                Link(destination: buyMeACoffeeURL) { Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill") }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // fixed-height pane: nothing to scroll
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
            Section("Known devices") {
                Toggle("Notify when a known device joins the network", isOn: $knownJoin)
                Toggle("Notify when a known device leaves the network", isOn: $knownLeave)
            }
            Section("New devices") {
                Toggle("Notify when a new device joins the network", isOn: $newJoin)
                Toggle("Notify when a new device leaves the network", isOn: $newLeave)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: [newJoin, newLeave, knownJoin, knownLeave]) {
            if [newJoin, newLeave, knownJoin, knownLeave].contains(true) { askToNotify() }  // permission is asked for here, not at launch
        }
    }
}

struct ScanPrefs: View {
    @AppStorage("scanInterface") var name = ""
    @AppStorage("scanFrom") var from = ""
    @AppStorage("scanTo") var to = ""
    @AppStorage("savedRanges") var savedRaw = ""  // "from - to" entries, one per line (no @State: swiftc here has no macro plugin)
    var saved: [String] { savedRaw.split(separator: "\n").map(String.init) }
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
            if p.count == 2 { from = p[0]; to = p[1] }
        })
    }
    var firstHost: String { net.map { ipv4($0.hosts.first ?? $0.base) } ?? "" }
    var lastHost: String { net.map { ipv4($0.hosts.last ?? $0.last) } ?? "" }
    func fill() { from = firstHost; to = lastHost }  // real values, not placeholders, so typing edits them
    func store(_ list: [String]) { savedRaw = list.joined(separator: "\n") }

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
            Section("Scan range") {
                HStack {
                    Picker("Saved ranges", selection: selected) {
                        Text(saved.isEmpty ? "None saved" : "Choose…").tag("")
                        ForEach(saved, id: \.self) { Text($0).tag($0) }
                    }
                    Button { store(saved.filter { $0 != selected.wrappedValue }) } label: { Image(systemName: "trash") }
                        .disabled(selected.wrappedValue.isEmpty).help("Delete the selected saved range")
                }
                TextField("From", text: $from)
                TextField("To", text: $to)
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
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty { fill() } }
        .onChange(of: name) { fill() }
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
                applyStayOnTop()
                if UserDefaults.standard.bool(forKey: "liveAtLaunch") && !m.started { m.liveScan() }
            }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: ScanModel
    @AppStorage("wrapText") var wrapText = false
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
    var body: some View { chrome.modifier(Reactions(m: m)) }

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
            dropdown("Check Ports", $m.mode, [("Off", Mode.off), ("Common", .common), ("All (slow)", .all)])
                .help("Which ports to check on each device. Changing this rescans.")
            Picker("View", selection: $m.view) {
                Text("Devices").tag(ViewKind.devices)
                Text("Ports").tag(ViewKind.ports)
                Text("Public").tag(ViewKind.exposed)
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
                TableColumn(f.title, sortUsing: FieldOrder(f)) { d in cell(d, f) }
                    .customizationID(f.rawValue)
                    .defaultVisibility(startHidden.contains(f) ? .hidden : .automatic)
            }
        } rows: {
            ForEach(rows) { TableRow($0) }
        }
        .contextMenu(forSelectionType: String.self) { ids in menu(ids) }
        .background(TableAccess(m: m))
    }

    // The built-in prompt stays left-aligned on macOS, so the prompt is drawn on top instead: faint and italic, so an empty
    // note reads as an invitation, not as typed text.
    func noteField(_ d: Device) -> some View {
        let text = Binding(get: { m.device(d.ip)?.note ?? "" }, set: { m.setNote(d, $0) })
        return ZStack(alignment: .trailing) {
            if text.wrappedValue.isEmpty { Text("Add a note").italic().foregroundStyle(.tertiary).allowsHitTesting(false) }
            TextField("", text: text).labelsHidden().multilineTextAlignment(.trailing)  // a titled field would show the title as its own prompt
        }
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
            noteField(d).textFieldStyle(.plain)
        } else if d.wait.contains(f) && d.text(f).isEmpty {
            Spinner()
        } else if f == .ping {
            Circle().fill(d.ping ? Color.green : Color.red).frame(width: 9, height: 9)
                .accessibilityLabel(d.ping ? "Online" : "No ping reply")
        } else if f == .ports {
            Text(d.ports.map { String($0.port) }.joined(separator: ", ")).font(.system(.callout, design: .monospaced))
                .lineLimit(1).help(d.text(.ports))
        } else {
            Text(d.text(f)).font(codeFields.contains(f) ? .system(.callout, design: .monospaced) : .body).lineLimit(1)
        }
    }

    // One lazy stack per column, so cards sit directly under each other whatever their heights.
    func cards(_ rows: [Device]) -> some View {
        GeometryReader { geo in
            let n = max(1, Int((geo.size.width - 20) / 332))  // 320 wide + 12 spacing, inside 16 padding
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cardColumns(rows, n), id: \.first?.ip) { column in
                        LazyVStack(spacing: 12) { ForEach(column) { card($0) } }
                    }
                }.padding(16)
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
                    Text(m.title(d)).font(.title3.bold())
                    row("Hostname", d.host, .host, d)
                    row("Manufacturer", d.vendor, nil, d)
                    row("Model", d.model, .model, d)
                    LabeledContent("Note") {
                        noteField(d)
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

extension Notification.Name { static let printList = Notification.Name("printList") }

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
