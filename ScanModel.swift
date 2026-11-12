// What the window shows and does. Scans run on their own threads and report back on the main thread.
import SwiftUI
import AppKit
import UserNotifications

// UNUserNotificationCenter traps in a bare binary, so both do nothing outside the app bundle.
func askToNotify() {  // macOS only asks the first time; later calls change nothing
    guard Bundle.main.bundleIdentifier != nil else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
}

func notify(_ title: String, _ body: String, ip: String) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    c.userInfo = ["ip": ip]  // read back when the notification is clicked
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

enum ViewKind: String, CaseIterable { case devices, ports, usage, exposed }

struct UsageSample: Identifiable { let id: Int, bytesIn: Int, bytesOut: Int }

struct UsageRow: Identifiable {
    let id: String, name: String, bytesIn: Int, bytesOut: Int
    var total: Int { bytesIn + bytesOut }
}

final class ScanModel: ObservableObject {
    @Published var rows = [Device]()
    @Published var selection: String?
    @Published var running = false
    @Published var live = UserDefaults.standard.bool(forKey: "defaultLive")
    @Published var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "defaultMode") ?? "") ?? .common
    @Published var view = ViewKind.devices
    @Published var search = ""
    @Published var filters = Filters()
    @Published var renaming: String?  // ip of the device whose name is being edited
    @Published var newName = ""
    @Published var editingTitle = false  // the details panel's title is being renamed (shares newName)
    var names = UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:]  // custom names, by Device.key
    @Published var favourites = Set(UserDefaults.standard.stringArray(forKey: "favourites") ?? [])
    @Published var notes = UserDefaults.standard.dictionary(forKey: "notes") as? [String: String] ?? [:]
    @Published var exposure: Exposure?
    @Published var exposureError: String?
    @Published var checkingExposure = false
    @Published var message = ""
    @Published var usage = [String: [UsageSample]]()  // recent traffic between this Mac and each address, by ip
    @Published var usageTotal = [String: (bytesIn: Int, bytesOut: Int)]()  // since launch
    @Published var usageSort = [KeyPathComparator(\UsageRow.total, order: .reverse)]
    private var usageTick = 0
    private var monitoring = false
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

    // What the Device column shows; a custom name is shown exactly as typed.
    func title(_ d: Device) -> String {
        d.hostname.isEmpty ? d.ip : names[d.key] != nil ? d.hostname : displayName(d.hostname)
    }

    private func cellWidth(_ d: Device, _ f: Field) -> CGFloat {
        func width(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), body = NSFont.systemFont(ofSize: 13)
        switch f {
        case .hostname:
            return 26 + width(title(d), body)
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
        monitorUsage()
        message = "Finding devices..."
        Thread.detachNewThread { [weak self] in
            var end = "Scan complete"
            do {
                let net = try chosenNet()
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

    // Samples nettop every few seconds, once. The first sample only sets the baseline.
    private func monitorUsage() {
        guard !monitoring else { return }
        monitoring = true
        Thread.detachNewThread { [weak self] in
            var previous: [String: Conn]?
            while self != nil {
                if let now = nettopSample() {
                    let step = previous.map { usageStep(previous: $0, now: now) }
                    previous = now
                    DispatchQueue.main.async { if let step { self?.addUsage(step) } }
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func addUsage(_ step: [String: (bytesIn: Int, bytesOut: Int)]) {
        usageTick += 1
        for ip in Set(rows.map(\.ip)).union(step.keys) {
            let d = step[ip] ?? (0, 0)
            usage[ip, default: []].append(UsageSample(id: usageTick, bytesIn: d.bytesIn, bytesOut: d.bytesOut))
            if usage[ip]!.count > 150 { usage[ip]!.removeFirst() }
            let t = usageTotal[ip] ?? (0, 0)
            usageTotal[ip] = (t.bytesIn + d.bytesIn, t.bytesOut + d.bytesOut)
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
            if let n = names[d.key] { d.hostname = n }
            d.note = notes[d.key] ?? ""
            d.wait = Field.names.union(mode == .off ? [] : [.ports, .identification])
            if let i = index(d.ip) { rows[i] = d } else { rows.append(d) }
        case .update(var d):
            if let n = names[d.key] { d.hostname = n }
            if let i = index(d.ip) {
                d.ping = rows[i].ping
                d.note = notes[d.key] ?? ""
                rows[i] = d
            }
            done += 1
            message = (mode == .off ? "Looking up names... " : "Checking ports... ") + "\(done) of \(total ?? 0)"
        }
        if live && done == total { message = "Live: watching for changes" }
        if done == total { passFinished() }
        fitColumnsOnce()
    }

    // MARK: notifications

    private var lastPass = [String: Device]()  // the devices of the last finished pass, by Device.key
    private var lastRange = ""
    // Seen before this launch, or in the first scan of it. A newcomer stays "new" until the next launch.
    // shortcut: "seenDevices" only ever grows; prune it if networks with rotating MACs make it large.
    private var known = Set(UserDefaults.standard.stringArray(forKey: "seenDevices") ?? [])

    // Every finished pass lands here: compare it with the one before and say who joined or left.
    // A device is present while it pings or is still in the ARP cache (discover), so one missed ping is not a leave.
    private func passFinished() {
        let now = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let current = Set(now.keys)
        if range != lastRange {
            known.formUnion(current)  // first scan of this range: everything would "join"
        } else {
            for e in presenceEvents(previous: Set(lastPass.keys), current: current, known: known) {
                guard let d = e.joined ? now[e.key] : lastPass[e.key],
                      UserDefaults.standard.bool(forKey: "notify\(e.known ? "Known" : "New")\(e.joined ? "Join" : "Leave")") else { continue }
                notify("\(d.hostname.isEmpty ? d.ip : d.hostname) \(e.joined ? "joined" : "left") the network",
                       "\(e.known ? "Known" : "New") device · \(d.ip)" + (d.mac == "?" ? "" : " · \(d.mac)"), ip: d.ip)
            }
        }
        (lastPass, lastRange) = (now, range)
        let seen = Set(UserDefaults.standard.stringArray(forKey: "seenDevices") ?? [])
        if !current.isSubset(of: seen) { UserDefaults.standard.set(Array(seen.union(current)), forKey: "seenDevices") }
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

    func startRename(_ ip: String) {
        guard let d = device(ip) else { return }
        newName = d.hostname.isEmpty ? d.ip : d.hostname  // what the cell shows, so an IP-only device starts with its IP
        renaming = ip
    }

    // An empty name clears the custom one; the real hostname comes back on the next scan.
    func rename(_ ip: String, to name: String) {
        guard let i = index(ip) else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        if rows[i].hostname.isEmpty && name == rows[i].ip { return }  // unchanged IP placeholder isn't a name
        if name.isEmpty { names[rows[i].key] = nil } else { names[rows[i].key] = name; rows[i].hostname = name }
        UserDefaults.standard.set(names, forKey: "names")
    }

    func setNote(_ d: Device, _ text: String) {
        // the field writes its value back when it gains focus; republishing the same text would redraw it again, forever
        guard text != (device(d.ip)?.note ?? "") else { return }
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
