// What the window shows and does. Scans run on their own threads and report back on the main thread.
import SwiftUI
import AppKit

enum ViewKind: String, CaseIterable { case devices, ports, exposed }

final class ScanModel: ObservableObject {
    @Published var rows = [Device]()
    @Published var selection: String?
    @Published var running = false
    @Published var live = UserDefaults.standard.bool(forKey: "defaultLive")
    @Published var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "defaultMode") ?? "") ?? .common
    @Published var view = ViewKind.devices
    @Published var search = ""
    @Published var filters = Filters()
    @Published var favourites = Set(UserDefaults.standard.stringArray(forKey: "favourites") ?? [])
    @Published var notes = UserDefaults.standard.dictionary(forKey: "notes") as? [String: String] ?? [:]
    @Published var exposure: Exposure?
    @Published var exposureError: String?
    @Published var checkingExposure = false
    @Published var message = ""
    @Published var range = ""
    @Published var done = 0
    @Published var total: Int?  // nil until the first sweep has finished
    @Published var me = [String: String]()
    @Published var mine = Set<String>()
    @Published var scanningPorts = Set<String>()
    @Published var urls: [String: [String]] = UserDefaults.standard.data(forKey: "urls")
        .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]

    // Window state lives here, not in @State: SwiftUI's @State is a macro, and it needs a plugin only full Xcode installs.
    @Published var sortOrder = [FieldOrder(.ip)]
    @Published var pin = true  // this Mac sits on top until a header is clicked
    @Published var showDetails = false
    @Published var addURLFor: String?
    @Published var newURL = ""
    // Not @Published: the table reports every width change during a window resize, and each one would redraw the whole window.
    private var columns: TableColumnCustomization<Device> = UserDefaults.standard.data(forKey: "columns")
        .flatMap { try? JSONDecoder().decode(TableColumnCustomization<Device>.self, from: $0) } ?? TableColumnCustomization()
    private var saveColumnsLater: DispatchWorkItem?

    var columnsBinding: Binding<TableColumnCustomization<Device>> {
        Binding(get: { self.columns }, set: { [self] new in
            let shownChanged = Field.allCases.contains { new[visibility: $0.rawValue] != columns[visibility: $0.rawValue] }
            columns = new
            if shownChanged { objectWillChange.send() }
            saveColumnsLater?.cancel()
            let save = DispatchWorkItem { [self] in
                if let data = try? JSONEncoder().encode(columns) { UserDefaults.standard.set(data, forKey: "columns") }
            }
            saveColumnsLater = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: save)
        })
    }

    private var stop: Stop?
    private var session = 0
    var started: Bool { session > 0 }

    func device(_ ip: String?) -> Device? { rows.first { $0.ip == ip } }
    private func index(_ ip: String) -> Int? { rows.firstIndex { $0.ip == ip } }

    // MARK: the table underneath SwiftUI's Table

    private weak var table: NSTableView?
    private var keyMonitor: Any?
    private var columnsFitted = false
    var hasTable: Bool { table?.window != nil }

    func attach(_ t: NSTableView) {
        guard table !== t else { return }
        table = t
        t.columnAutoresizingStyle = .noColumnAutoresizing  // columns keep their fitted widths, and a window resize no longer recalculates them
        if keyMonitor == nil {
            // The arrows only move the selection while the table has keyboard focus, so hand it focus when they're pressed.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard e.keyCode == 125 || e.keyCode == 126, let t = self?.table, let w = t.window, e.window === w else { return e }
                if (w.firstResponder as? NSView)?.isDescendant(of: t) == true { return e }
                if let field = w.firstResponder as? NSTextView, field.isEditable, !field.string.isEmpty { return e }  // typing a search
                w.makeFirstResponder(t)
                return e
            }
        }
        fitColumnsOnce()
    }

    // Once per launch, after the first pass has filled in the names.
    private func fitColumnsOnce() {
        guard !columnsFitted, let table, !rows.isEmpty, !running || done == total else { return }
        columnsFitted = true
        for c in table.tableColumns where !c.isHidden {
            guard let f = Field.allCases.first(where: { $0.title == c.title }) else { continue }
            let widest = rows.map { cellWidth($0, f) }.max() ?? 0
            c.width = min(max(widest, c.headerCell.cellSize.width + 16) + 24, 480)  // 24 is the cell's own padding
        }
    }

    private func cellWidth(_ d: Device, _ f: Field) -> CGFloat {
        func width(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), body = NSFont.systemFont(ofSize: 13)
        switch f {
        case .hostname:
            return 26 + width(d.hostname.isEmpty ? d.ip : d.hostname, body)
                + (d.vendor.isEmpty ? 0 : 8 + width(d.vendor, .systemFont(ofSize: 10)))
                + (isFavourite(d) ? 22 : 0)
        case .ping: return 9
        case .ports: return width(d.ports.map { String($0.port) }.joined(separator: ", "), mono)
        default: return width(d.text(f), codeFields.contains(f) ? mono : body)
        }
    }

    // MARK: scanning

    func liveScan() {
        if running && live { toggle(); return }
        if let stop { stop.set(); finish("") }
        live = true
        start()
    }

    // Picking a port level applies straight away instead of waiting for the next scan.
    func portLevelChanged() {
        guard mode != .off, running || !rows.isEmpty else { return }
        if let stop { stop.set(); finish("") }
        start()
    }

    func toggle() {
        if let stop {
            stop.set()
            finish("Stopped")
        } else {
            start()
        }
    }

    func start() {
        guard stop == nil else { return }
        let stop = Stop()
        self.stop = stop
        session += 1
        let id = session, mode = mode, live = live, pause = UserDefaults.standard.double(forKey: "livePause")
        rows = []
        selection = nil
        running = true
        done = 0
        total = nil
        range = ""
        mine = Set(localIPs())
        message = "Finding devices..."
        Thread.detachNewThread { [weak self] in
            var end = "Scan complete"
            do {
                let net = try checkedNet(try localNet())
                DispatchQueue.main.async { if self?.session == id { self?.range = "Scan of \(net)" } }
                try events(net, mode, live: live, stop: stop, pause: pause) { e in
                    DispatchQueue.main.async { self?.handle(e, mode, live, id) }
                }
            } catch {
                end = "Error: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { if self?.session == id { self?.finish(end) } }
        }
    }

    private func finish(_ text: String) {
        session += 1  // late events from the old scan are ignored
        stop = nil
        running = false
        for i in rows.indices { rows[i].wait = [] }
        message = text
        fitColumnsOnce()
    }

    private func handle(_ e: ScanEvent, _ mode: Mode, _ live: Bool, _ id: Int) {
        guard id == session else { return }
        switch e {
        case .seen(let count, let seen):
            total = count
            done = 0
            if let s = selection, seen[s] == nil { selection = nil }
            let kept = rows.filter { seen[$0.ip] != nil }.map { (d: Device) -> Device in
                var d = d
                d.ping = seen[d.ip] ?? false
                return d
            }
            if kept.count != rows.count || zip(kept, rows).contains(where: { $0.ping != $1.ping }) { rows = kept }
        case .row(var d):
            d.note = notes[d.key] ?? ""
            d.wait = Field.names.union(mode == .off ? [] : [.ports, .identification])
            if let i = index(d.ip) { rows[i] = d } else { rows.append(d) }
        case .update(var d):
            if let i = index(d.ip) {
                d.ping = rows[i].ping
                d.note = notes[d.key] ?? ""
                rows[i] = d
            }
            done += 1
            message = (mode == .off ? "Looking up names... " : "Checking ports... ") + "\(done) of \(total ?? 0)"
        }
        if live && done == total { message = "Live: watching for changes" }
        fitColumnsOnce()
    }

    func scanEveryPort(_ ip: String) {
        guard let i = index(ip), !scanningPorts.contains(ip) else { return }
        scanningPorts.insert(ip)
        rows[i].ports = []
        rows[i].wait.formUnion([.ports, .identification])
        Thread.detachNewThread { [weak self] in
            let result = Result { try portInfo(try privateIP(ip), .all) }
            DispatchQueue.main.async { self?.portScanDone(ip, result) }
        }
    }

    private func portScanDone(_ ip: String, _ result: Result<(ports: [Port], identification: String), Error>) {
        scanningPorts.remove(ip)
        guard let i = index(ip) else { return }
        rows[i].wait.subtract([.ports, .identification])
        switch result {
        case .success(let r):
            rows[i].ports = r.ports
            rows[i].identification = r.identification
            rows[i].portsChecked = true
        case .failure(let e):
            message = "Port scan failed: \(e.localizedDescription)"
        }
    }

    // MARK: actions on a device

    func setNote(_ d: Device, _ text: String) {
        notes[d.key] = text.isEmpty ? nil : text
        UserDefaults.standard.set(notes, forKey: "notes")
        if let i = index(d.ip) { rows[i].note = text }
    }

    func isFavourite(_ d: Device) -> Bool { favourites.contains(d.key) }

    func toggleFavourite(_ d: Device) {
        if favourites.remove(d.key) == nil { favourites.insert(d.key) }
        UserDefaults.standard.set(Array(favourites), forKey: "favourites")
    }

    @discardableResult
    func openInSafari(_ s: String) -> Bool {
        do {
            let url = try webURL(s)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                throw ScanError("Safari isn't installed")
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            message = "Could not open Safari: \(error.localizedDescription)"
            return false
        }
    }

    func addURL(_ s: String, for ip: String) {
        let u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard openInSafari(u), !(urls[ip] ?? []).contains(u) else { return }  // saved only once it's accepted
        urls[ip, default: []].append(u)
        if let data = try? JSONEncoder().encode(urls) { UserDefaults.standard.set(data, forKey: "urls") }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        message = "Copied"
    }

    // One call to ip-api.com (reveals your public IP to them); shown in the details panel.
    func loadPublicInfo() {
        if me.isEmpty { fetchPublicInfo {} }
    }

    private func fetchPublicInfo(then done: @escaping () -> Void) {
        guard let url = URL(string: "http://ip-api.com/json/?fields=isp,country,query") else { return done() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            DispatchQueue.main.async {
                if let j { self.me = j }
                done()
            }
        }.resume()
    }

    // Asks Shodan what it has seen open on our public address, which reveals that address to them.
    // Probing it from inside the network would only reach the router, not what the internet can reach.
    func checkExposure() {
        guard !checkingExposure else { return }
        checkingExposure = true
        exposureError = nil
        fetchPublicInfo { [weak self] in self?.lookUpExposure() }
    }

    private func lookUpExposure() {
        guard let ip = me["query"].flatMap(publicIP), let url = URL(string: "https://internetdb.shodan.io/\(ip)") else {
            exposureError = "Couldn't find this network's public address"
            checkingExposure = false
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result = Result { () -> Exposure in
                guard let data, let http = response as? HTTPURLResponse else { throw error ?? ScanError("No answer from Shodan") }
                return try parseExposure(data, status: http.statusCode)
            }
            DispatchQueue.main.async {
                self.checkingExposure = false
                switch result {
                case .success(let e): self.exposure = e
                case .failure(let e): self.exposureError = e.localizedDescription
                }
            }
        }.resume()
    }
}
