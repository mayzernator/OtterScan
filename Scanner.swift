import SystemConfiguration
// OtterScan's scanner: finds devices on the local network. No UI here; App.swift shows the results.
import Foundation

func prepareProcess() {
    signal(SIGPIPE, SIG_IGN)  // a device hanging up mid-write would otherwise kill the app
    // macOS defaults to 256 open files; a port scan holds far more sockets than that
    var limit = rlimit()
    getrlimit(RLIMIT_NOFILE, &limit)
    limit.rlim_cur = min(8192, limit.rlim_max)
    setrlimit(RLIMIT_NOFILE, &limit)
}

func errorText() -> String { String(cString: strerror(errno)) }

func inet(_ ip: String, _ port: Int = 0) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = UInt16(port).bigEndian
    _ = inet_pton(AF_INET, ip, &a.sin_addr)
    return a
}

func withAddr<R>(_ a: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafeMutablePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

func setNonblocking(_ s: Int32, _ on: Bool) {
    let flags = fcntl(s, F_GETFL)
    _ = fcntl(s, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
}

func setTimeouts(_ s: Int32) {
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
}

// "Wi-Fi", "Ethernet"... as System Settings names them; empty when macOS has no name for it
func friendlyInterfaceNames() -> [String: String] {
    var out = [String: String]()
    for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
        if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? { out[bsd] = n }
    }
    return out
}

struct Iface { let name: String, ip: UInt32, mask: UInt32, mac: String }

func interfaces() -> [Iface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    func value(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }
    var macs = [String: String](), out = [Iface]()
    var p = head
    while let a = p {
        let name = String(cString: a.pointee.ifa_name)
        if let addr = a.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_LINK) {
            let raw = UnsafeRawPointer(addr)
            let sdl = raw.assumingMemoryBound(to: sockaddr_dl.self).pointee
            let at = raw.advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(sdl.sdl_nlen))
            macs[name] = (0..<Int(sdl.sdl_alen)).map { String(format: "%02x", at.load(fromByteOffset: $0, as: UInt8.self)) }.joined(separator: ":")
        }
        p = a.pointee.ifa_next
    }
    p = head
    while let a = p {
        if let addr = a.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET), let mask = a.pointee.ifa_netmask {
            let name = String(cString: a.pointee.ifa_name)
            out.append(Iface(name: name, ip: value(addr), mask: value(mask), mac: macs[name] ?? ""))
        }
        p = a.pointee.ifa_next
    }
    return out
}

func localNet() throws -> Net {
    let s = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(s) }
    var out = inet("8.8.8.8", 80)  // UDP connect sends nothing; just picks the route
    guard withAddr(&out, { connect(s, $0, $1) }) == 0 else { throw ScanError("No network connection (\(errorText()))") }
    var me = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withAddr(&me, { p, _ in getsockname(s, p, &len) }) == 0 else { throw ScanError(errorText()) }
    let ip = UInt32(bigEndian: me.sin_addr.s_addr)
    return Net(ip, interfaces().first { $0.ip == ip }?.mask.nonzeroBitCount ?? 24)
}

// The network to scan: the interface and optional From/To range picked in Settings, else this Mac's own subnet.
func chosenNets() throws -> [Net] {
    let d = UserDefaults.standard
    let typed = (d.string(forKey: "scanTargets") ?? "").trimmingCharacters(in: .whitespaces)
    if !typed.isEmpty { return try parseNets(typed) }  // a typed list replaces the interface and From/To
    var net = try localNet()
    let name = d.string(forKey: "scanInterface") ?? ""
    if let i = interfaces().first(where: { $0.name == name }) { net = Net(i.ip, i.mask.nonzeroBitCount) }  // a vanished interface falls back to automatic
    let r = savedRange(net, in: d.string(forKey: "scanRanges") ?? "")  // None for a network never customised: scan all of it
    return [try checkedNet(try customRange(net, r?.from ?? "", r?.to ?? ""))]
}

// every interface, so scanning a second attached network still finds this Mac
func localIPs() -> [String] { interfaces().map { ipv4($0.ip) } }

// MARK: discovery

func checksum(_ b: [UInt8]) -> UInt16 {
    var s: UInt32 = 0
    for i in stride(from: 0, to: b.count - 1, by: 2) { s += UInt32(b[i]) << 8 | UInt32(b[i + 1]) }
    s = (s >> 16) + (s & 0xffff)
    return ~UInt16(truncatingIfNeeded: s + (s >> 16))
}

let ECHO: [UInt8] = {
    var p: [UInt8] = [8, 0, 0, 0, 0x4c, 0x53, 0, 1]
    let sum = checksum(p)
    p[2] = UInt8(sum >> 8)
    p[3] = UInt8(sum & 255)
    return p
}()

// One ping at launch so macOS shows its Local Network prompt right away instead of in the middle of the first scan.
func askForLocalNetwork() {
    guard let net = try? localNet() else { return }
    let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard s >= 0 else { return }
    defer { close(s) }
    var a = inet(ipv4(net.base + 1))
    _ = withAddr(&a) { sendto(s, ECHO, ECHO.count, 0, $0, $1) }
}

// Ping every host from one socket, not a `ping` process each.
func sweep(_ net: Net) throws -> Set<String> {
    let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard s >= 0 else { throw ScanError(errorText()) }
    defer { close(s) }
    setNonblocking(s, true)
    var up = Set<String>()
    var buf = [UInt8](repeating: 0, count: 1500)

    func drain(_ ms: Int32) {
        var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
        var wait = ms
        while poll(&pfd, 1, wait) > 0 {
            wait = 0
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withAddr(&from) { p, _ in recvfrom(s, &buf, buf.count, 0, p, &len) }
            // shortcut: macOS includes the IP header in replies, other systems would need offset 0
            // the socket also hears replies to other programs' pings, so only count hosts in the range being scanned
            let who = UInt32(bigEndian: from.sin_addr.s_addr)
            if n > 20 && buf[20] == 0 && net.contains(who) { up.insert(ipv4(who)) }
        }
    }

    let hosts = net.hosts
    var sent = 0
    for _ in 0..<2 {  // second pass catches hosts whose ARP entry wasn't ready
        for (i, ip) in hosts.enumerated() {
            var a = inet(ipv4(ip))
            if withAddr(&a, { sendto(s, ECHO, ECHO.count, 0, $0, $1) }) >= 0 {
                sent += 1
            } else if errno == ENOBUFS {  // empty addresses fail instantly; only a full queue needs a pause
                drain(10)
            }
            if i % 64 == 63 { drain(50) }
        }
    }
    let end = Date().addingTimeInterval(1.5)
    while Date() < end { drain(100) }
    // Without Local Network permission every send fails at once.
    if sent == 0 && hosts.count > 2 {
        throw ScanError("OtterScan needs Local Network access. Turn it on in System Settings > Privacy & Security > Local Network, then scan again.")
    }
    return up
}

// Reads the kernel's neighbor table directly: the `arp` and `ndp` commands come back empty when run from this app.
func neighbors(_ family: Int32) -> [(ip: String, mac: String)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO]
    var n = 0
    guard sysctl(&mib, 6, nil, &n, nil, 0) == 0 else { return [] }
    n *= 2  // the table can grow between the two calls
    var b = [UInt8](repeating: 0, count: n)
    guard sysctl(&mib, 6, &b, &n, nil, 0) == 0 else { return [] }
    var out = [(ip: String, mac: String)]()
    var i = 0
    while i + 100 < n {
        let len = Int(b[i]) | Int(b[i + 1]) << 8
        if len == 0 { break }
        let sa = i + MemoryLayout<rt_msghdr>.size
        let dl = sa + ((Int(b[sa]) + 3) & ~3)
        let nlen = Int(b[dl + 5]), alen = Int(b[dl + 6])
        if alen == 6, dl + 8 + nlen + 6 <= n {
            let at = dl + 8 + nlen
            let mac = b[at..<(at + 6)].map { String(format: "%02x", $0) }.joined(separator: ":")
            if family == AF_INET {
                out.append((b[(sa + 4)..<(sa + 8)].map(String.init).joined(separator: "."), mac))
            } else {
                var a = Array(b[(sa + 8)..<(sa + 24)])
                if a[0] == 0xfe && a[1] & 0xc0 == 0x80 { a[2] = 0; a[3] = 0 }  // the kernel hides the interface index here
                var text = [CChar](repeating: 0, count: 64)
                inet_ntop(AF_INET6, a, &text, 64)
                out.append((String(cString: text), mac))
            }
        }
        i += len
    }
    return out
}

func arpTable() -> [String: String] {
    Dictionary(neighbors(AF_INET).map { ($0.ip, $0.mac) }, uniquingKeysWith: { _, new in new })
}

// MAC -> this device's IPv6 addresses
func ndpTable() -> [String: V6] {
    var t = [String: V6]()
    for (ip, mac) in neighbors(AF_INET6) {
        var v = t[mac] ?? V6()
        if ip.lowercased().hasPrefix("fe80") {
            if v.local.isEmpty { v.local = ip }
        } else if v.global.isEmpty {
            v.global = ip
        }
        t[mac] = v
    }
    return t
}

// Every device on net.
func discover(_ nets: [Net]) throws -> [Found] {
    var up = Set<String>()
    for net in nets { up.formUnion(try sweep(net)) }
    let arp = arpTable(), ndp = ndpTable()
    // firewalled hosts ignore ping but still ARP
    let cached = arp.filter { k, v in ipv4(k).map { ip in nets.contains { $0.contains(ip) } } == true && v != "ff:ff:ff:ff:ff:ff" }.keys
    return up.union(cached).sorted { (ipv4($0) ?? 0) < (ipv4($1) ?? 0) }.map {
        Found($0, arp[$0] ?? "?", up.contains($0), arp[$0].flatMap { ndp[$0] } ?? V6())
    }
}

// MARK: names

func udp(_ ip: String, _ port: Int, _ pkt: [UInt8]) -> [UInt8] {
    let s = socket(AF_INET, SOCK_DGRAM, 0)
    guard s >= 0 else { return [] }
    defer { close(s) }
    setTimeouts(s)
    var to = inet(ip, port)
    var buf = [UInt8](repeating: 0, count: 2048)
    for _ in 0..<2 {  // UDP gets dropped when dozens of queries go out at once
        if withAddr(&to, { sendto(s, pkt, pkt.count, 0, $0, $1) }) < 0 { continue }
        let n = recv(s, &buf, buf.count, 0)
        if n >= 0 { return Array(buf[0..<n]) }
    }
    return []
}

func dnsName(_ ip: String) -> String {  // full reverse-DNS name via the system resolver
    var a = inet(ip)
    var host = [CChar](repeating: 0, count: 1025)
    return withAddr(&a, { getnameinfo($0, $1, &host, 1025, nil, 0, NI_NAMEREQD) }) == 0 ? String(cString: host) : ""
}

struct Truncated: Error {}

func byte(_ r: [UInt8], _ i: Int) throws -> UInt8 {
    guard r.indices.contains(i) else { throw Truncated() }
    return r[i]
}

func readName(_ msg: [UInt8], _ start: Int, depth: Int = 0) throws -> String {
    guard depth < 64 else { throw Truncated() }  // pointer loop
    var parts = [String](), i = start
    while i < msg.count {
        let n = Int(msg[i])
        if n == 0 { return parts.joined(separator: ".") }
        if n & 0xC0 == 0xC0 {  // compression pointer
            let target = (n & 0x3F) << 8 | Int(try byte(msg, i + 1))
            return (parts + [try readName(msg, target, depth: depth + 1)]).joined(separator: ".")
        }
        parts.append(String(decoding: msg[min(i + 1, msg.count)..<min(i + 1 + n, msg.count)], as: UTF8.self))
        i += n + 1
    }
    return parts.joined(separator: ".")
}

// First PTR answer in a DNS reply, or "". Replies come off the network, so tolerate garbage.
func parsePTR(_ r: [UInt8]) -> String {
    guard r.count > 12, r[6] != 0 || r[7] != 0 else { return "" }
    do {
        var i = 12
        while try byte(r, i) != 0 { i += Int(r[i]) + 1 }
        i += 5  // name end + qtype + qclass
        while try byte(r, i) & 0xC0 != 0xC0, r[i] != 0 { i += Int(r[i]) + 1 }
        i += r[i] & 0xC0 == 0xC0 ? 2 : 1
        return try readName(r, i + 10)  // skip type, class, ttl, rdlen
    } catch { return "" }
}

func header(_ words: [UInt16]) -> [UInt8] { words.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] } }

func mdnsQuery(_ ip: String, _ labels: [String], _ type: UInt16) -> [UInt8] {  // unicast mDNS: ask the device itself
    var q = header([0, 0, 1, 0, 0, 0])
    for p in labels { q += [UInt8(p.utf8.count)] + Array(p.utf8) }
    return udp(ip, 5353, q + [0] + header([type, 1]))
}

func mdnsName(_ ip: String) -> String {  // the device's .local name
    parsePTR(mdnsQuery(ip, ip.split(separator: ".").reversed().map(String.init) + ["in-addr", "arpa"], 12))
}

func skipName(_ r: [UInt8], _ start: Int) throws -> Int {
    var i = start
    while true {
        let n = Int(try byte(r, i))
        if n == 0 { return i + 1 }
        if n & 0xC0 == 0xC0 { return i + 2 }
        i += n + 1
    }
}

// Every TXT record in a DNS reply as lowercase key -> value. Replies come off the network, so tolerate garbage.
func parseTXT(_ r: [UInt8]) -> [String: String] {
    var out = [String: String]()
    do {
        func word(_ i: Int) throws -> Int { Int(try byte(r, i)) << 8 | Int(try byte(r, i + 1)) }
        var i = 12
        for _ in 0..<(try word(4)) { i = try skipName(r, i) + 4 }
        for _ in 0..<(try word(6) + word(8) + word(10)) {
            i = try skipName(r, i)
            let end = i + 10 + (try word(i + 8))
            guard end <= r.count else { break }
            if try word(i) == 16 {
                var j = i + 10
                while j < end, j + 1 + Int(r[j]) <= end {
                    let pair = String(decoding: r[(j + 1)..<(j + 1 + Int(r[j]))], as: UTF8.self)
                    if let eq = pair.firstIndex(of: "="), out[pair[..<eq].lowercased()] == nil { out[pair[..<eq].lowercased()] = String(pair[pair.index(after: eq)...]) }
                    j += Int(r[j]) + 1
                }
            }
            i = end
        }
    } catch {}
    return out
}

// Services whose TXT records usually say what the device is. AirPlay goes first: Apple devices answer it quickly and tuck
// the device-info record into the same reply, whereas asking for device-info directly gets no answer.
let MODEL_SERVICES = ["_airplay._tcp", "_device-info._tcp", "_ipp._tcp", "_googlecast._tcp"]

// Only asked of devices that already answered mDNS, because each silent service costs a timeout.
func modelInfo(_ ip: String) -> (maker: String, model: String) {
    for s in MODEL_SERVICES {
        let t = parseTXT(mdnsQuery(ip, s.split(separator: ".").map(String.init) + ["local"], 12))
        guard let id = ["model", "md", "ty", "usb_mdl"].lazy.compactMap({ t[$0] }).first, !id.isEmpty else { continue }
        let model = friendlyModel(id)
        return (t["manufacturer"] ?? t["usb_mfg"] ?? (model == id ? "" : "Apple"), model)
    }
    return ("", "")
}

// Apple devices advertise their user-chosen name ("Alex's MacBook Pro") as a Bonjour instance name; ask for it directly.
func friendlyName(_ ip: String) -> String {
    for svc in ["_companion-link", "_airplay"] {
        var q = [UInt8]()
        for p in [svc, "_tcp", "local"] { q += [UInt8(p.utf8.count)] + Array(p.utf8) }
        let suffix = "." + svc + "._tcp.local"
        let r = parsePTR(udp(ip, 5353, header([0, 0, 1, 0, 0, 0]) + q + [0] + header([12, 1])))
        if r.hasSuffix(suffix), r.count > suffix.count { return String(r.dropLast(suffix.count)) }
    }
    return ""
}

// NetBIOS node status reply -> (host name, workgroup/domain)
func parseNbstat(_ r: [UInt8]) -> (String, String) {
    var host = "", domain = ""
    guard r.count > 56 else { return (host, domain) }
    for k in 0..<Int(r[56]) {
        let start = 57 + 18 * k
        guard start + 18 <= r.count else { break }
        let name = String(decoding: r[start..<(start + 15)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if r[start + 15] == 0 {
            if r[start + 16] & 0x80 != 0 {
                if domain.isEmpty { domain = name }
            } else if host.isEmpty { host = name }
        }
    }
    return (host, domain)
}

func smbNames(_ ip: String) -> (String, String) {
    let pkt = header([1, 0, 1, 0, 0, 0]) + [0x20] + Array(("CK" + String(repeating: "A", count: 30)).utf8) + [0] + header([0x21, 1])
    return parseNbstat(udp(ip, 137, pkt))
}

// MARK: ports

let servicesLock = NSLock()  // getservbyport returns a shared static buffer

func service(_ p: Int) -> String {
    if let name = PORTS[p] { return name }
    servicesLock.lock()
    defer { servicesLock.unlock() }
    guard let e = getservbyport(Int32(UInt16(p).bigEndian), "tcp") else { return "Unknown" }
    return String(cString: e.pointee.s_name).replacingOccurrences(of: "-", with: " ").capitalized
}

let BATCH = 512  // sockets open at once per device; 8 devices at a time stays under the 8192 file limit

// Connect-scan `ports` on one device with non-blocking sockets. Returns the open ones, sorted.
func openPorts(_ ip: String, _ ports: [Int], _ stop: Stop? = nil) throws -> [Int] {
    var found = [Int]()
    for start in stride(from: 0, to: ports.count, by: BATCH) {
        if stop?.isSet == true { break }
        var fds = [pollfd](), who = [Int]()
        defer { for f in fds where f.fd >= 0 { close(f.fd) } }  // filtered ports never answer
        for p in ports[start..<min(start + BATCH, ports.count)] {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { throw ScanError(errorText()) }
            setNonblocking(s, true)
            var a = inet(ip, p)
            let rc = withAddr(&a) { connect(s, $0, $1) }
            if rc != 0 && errno == EINPROGRESS {
                fds.append(pollfd(fd: s, events: Int16(POLLOUT), revents: 0))
                who.append(p)
            } else {
                if rc == 0 { found.append(p) }
                close(s)
            }
        }
        var pending = fds.count
        let end = Date().addingTimeInterval(0.4)
        while pending > 0 {
            let left = end.timeIntervalSinceNow
            if left <= 0 { break }
            if poll(&fds, nfds_t(fds.count), Int32(left * 1000) + 1) <= 0 { continue }
            for i in fds.indices where fds[i].fd >= 0 && fds[i].revents != 0 {
                var e: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fds[i].fd, SOL_SOCKET, SO_ERROR, &e, &size)
                if e == 0 { found.append(who[i]) }
                close(fds[i].fd)
                fds[i].fd = -1
                pending -= 1
            }
        }
    }
    return found.sorted()
}

func serverHeader(_ reply: [UInt8]) -> String? {
    for line in String(decoding: reply, as: UTF8.self).split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("server:") {
        let value = line.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
    }
    return nil
}

func identify(_ ip: String, _ ports: [Int]) -> String {  // HTTP "Server" header as a cheap fingerprint
    for p in [80, 8080] where ports.contains(p) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { continue }
        defer { close(s) }
        setNonblocking(s, true)
        var a = inet(ip, p)
        if withAddr(&a, { connect(s, $0, $1) }) != 0 {
            guard errno == EINPROGRESS else { continue }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            var e: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&pfd, 1, 1000) > 0, getsockopt(s, SOL_SOCKET, SO_ERROR, &e, &size) == 0, e == 0 else { continue }
        }
        setNonblocking(s, false)
        setTimeouts(s)
        let req = Array("HEAD / HTTP/1.0\r\nHost: x\r\n\r\n".utf8)
        guard send(s, req, req.count, 0) == req.count else { continue }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(s, &buf, buf.count, 0)
        if n > 0, let server = serverHeader(Array(buf[0..<n])) { return server }
    }
    return ""
}

// The "customPorts" setting (the CLI sets it for its own run only, in the argument domain).
func portsToScan(_ mode: Mode) throws -> [Int] {
    switch mode {
    case .all: return Array(1...65535)
    case .custom: return try parsePorts(UserDefaults.standard.string(forKey: "customPorts") ?? "")
    default: return Array(PORTS.keys)
    }
}

func portInfo(_ ip: String, _ mode: Mode, _ stop: Stop? = nil) throws -> (ports: [Port], identification: String) {
    let found = try openPorts(ip, try portsToScan(mode), stop)
    return (found.map { Port(port: $0, name: service($0)) }, identify(ip, found))
}

// MARK: scan

func detail(_ f: Found, _ mode: Mode, _ stop: Stop) throws -> Device {
    var d = basic(f)
    d.dns = dnsName(f.ip)
    d.mdns = mdnsName(f.ip)
    (d.smb, d.smbDomain) = smbNames(f.ip)
    d.host = [d.dns, d.mdns, d.smb].first { !$0.isEmpty } ?? ""
    d.hostname = [friendlyName(f.ip), d.host].first { !$0.isEmpty } ?? ""
    if !d.mdns.isEmpty {
        let info = modelInfo(f.ip)
        d.model = info.model
        // a randomised MAC (iPhones) hides the maker, but the model gives it away
        if d.vendor.isEmpty || d.vendor == "Private address", !info.maker.isEmpty { d.vendor = cleanVendor(info.maker) }
    }
    d.kind = deviceKind("\(d.dns) \(d.mdns) \(d.smb) \(d.vendor) \(d.model)")
    if mode != .off {
        (d.ports, d.identification) = try portInfo(f.ip, mode, stop)
        d.portsChecked = true
    }
    return d
}

// Calls `emit` once per device as each finishes, one at a time. Stop cancels whatever hasn't started.
func details(_ found: [Found], _ mode: Mode, _ stop: Stop, _ emit: @escaping (Device) -> Void) throws {
    let lock = NSLock(), group = DispatchGroup()
    var next = 0
    var failure: Error?
    // real threads: these block on the network, which would starve GCD's shared pool
    for _ in 0..<min(mode.workers, found.count) {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            while true {
                lock.lock()
                guard next < found.count, failure == nil, !stop.isSet else { lock.unlock(); return }
                let f = found[next]
                next += 1
                lock.unlock()
                do {
                    let d = try detail(f, mode, stop)
                    lock.lock(); emit(d); lock.unlock()
                } catch {
                    lock.lock(); failure = error; lock.unlock()
                }
            }
        }
    }
    group.wait()
    if let failure { throw failure }
}

let LIVE_PAUSE = 5.0  // seconds between live passes; each pass pings the whole range

// The scan as messages for the UI. Live repeats until stopped, looking up only new devices.
func events(_ nets: [Net], _ mode: Mode = .off, live: Bool = false, stop: Stop = Stop(), pause: Double = LIVE_PAUSE,
            find: ([Net]) throws -> [Found] = discover,
            lookup: ([Found], Mode, Stop, @escaping (Device) -> Void) throws -> Void = details,
            emit: @escaping (ScanEvent) -> Void) throws {
    var known = Set<String>()
    while !stop.isSet {
        let found = try find(nets)
        let new = found.filter { !known.contains($0.ip + $0.mac) }  // (ip, mac): a reassigned IP counts as new
        known = Set(found.map { $0.ip + $0.mac })
        emit(.seen(total: new.count, seen: Dictionary(found.map { ($0.ip, $0.ping) }, uniquingKeysWith: { a, _ in a })))
        for f in new { emit(.row(basic(f))) }
        try lookup(new, mode, stop) { emit(.update($0)) }
        if !live { return }
        var waited = 0.0
        while waited < pause && !stop.isSet {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
    }
}

// Usage: OtterScan --cli [RANGES] [--ports | --ports=22,80,8000-8100 | --all-ports] [--csv | --json]   (default: your subnet)
// RANGES is a comma-separated list of IPs and CIDRs, e.g. "192.168.1.10,192.168.2.0/24".
func runCLI(_ args: [String]) throws {
    prepareProcess()
    let plain = args.filter { !$0.hasPrefix("--") }
    let nets = try plain.first.map(parseNets) ?? [localNet()]
    let csv = args.contains("--csv"), json = args.contains("--json")
    if !csv && !json { print("Scanning \(nets.map(\.description).joined(separator: ", ")) ...") }  // keep stdout clean for export
    var mode: Mode = args.contains("--all-ports") ? .all : args.contains("--ports") ? .common : .off
    if let list = args.first(where: { $0.hasPrefix("--ports=") }).map({ String($0.dropFirst(8)) }) {
        _ = try parsePorts(list)  // fail before scanning
        UserDefaults.standard.setVolatileDomain(["customPorts": list], forName: UserDefaults.argumentDomain)
        mode = .custom
    }
    var rows = [Device]()
    try details(try discover(nets), mode, Stop()) { rows.append($0) }
    func cell(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
    rows.sort { (ipv4($0.ip) ?? 0) < (ipv4($1.ip) ?? 0) }
    if csv || json { print(exportText(rows, json: json), terminator: csv ? "" : "\n"); return }
    for d in rows {
        print(cell(d.ip, 16) + cell(d.mac, 19) + cell(d.hostname, 42) + cell(d.vendor, 30) + d.text(.ports))
    }
}
