// OtterScan's data types and address helpers. No networking and no UI here.
import Foundation

// Plain names, and also the list the "Common" port scan checks.
let PORTS: [Int: String] = [
    20: "FTP Data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "Email (SMTP)",
    53: "DNS", 80: "Website", 88: "Kerberos Login", 110: "Email (POP3)", 111: "RPC", 135: "Windows RPC",
    139: "Windows File Sharing (NetBIOS)", 143: "Email (IMAP)", 389: "Directory (LDAP)", 443: "Secure Website",
    445: "Windows File Sharing", 465: "Email (SMTPS)", 515: "Printer (LPD)", 548: "Mac File Sharing",
    554: "Video Stream (RTSP)", 587: "Email (Sending)", 631: "Printer (IPP)", 636: "Directory (Secure LDAP)",
    873: "Rsync Backup", 902: "VMware", 990: "Secure FTP", 993: "Email (Secure IMAP)", 995: "Email (Secure POP3)",
    1080: "SOCKS Proxy", 1433: "Microsoft SQL Server", 1521: "Oracle Database", 1723: "PPTP VPN",
    1883: "MQTT Smart Home", 2049: "NFS File Sharing", 2375: "Docker", 2376: "Docker (Secure)",
    3000: "Web App", 3128: "Web Proxy", 3260: "iSCSI Storage", 3268: "Active Directory Catalog",
    3306: "MySQL Database", 3389: "Windows Remote Desktop", 5000: "Web App or AirPlay", 5001: "Synology NAS",
    5060: "Phone System (SIP)", 5357: "Windows Device Discovery", 5432: "PostgreSQL Database",
    5555: "Android Debug", 5900: "Screen Sharing (VNC)", 5985: "Windows Remote Management",
    5986: "Windows Remote Management (Secure)", 6379: "Redis Database", 6443: "Kubernetes", 7000: "AirPlay",
    7680: "Windows Update Sharing", 7777: "Terraria", 8006: "Proxmox", 8008: "Chromecast", 8009: "Chromecast",
    8080: "Website (Alternate)", 8096: "Jellyfin Media", 8123: "Home Assistant", 8443: "Secure Website (Alternate)",
    8883: "MQTT Smart Home (Secure)", 9090: "Server Dashboard", 9100: "Printer", 9200: "Elasticsearch",
    10000: "Webmin", 11434: "Ollama AI", 25565: "Minecraft", 25575: "Minecraft Remote Console",
    27015: "Steam Game Server", 27017: "MongoDB Database", 32400: "Plex Media", 62078: "iPhone Sync"]

let OUI: [String: String] = {
    var table = [String: String]()
    for path in ["/opt/homebrew/share/nmap/nmap-mac-prefixes", "/usr/share/nmap/nmap-mac-prefixes"] {
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.first != "#" && line.count > 7 {
            table[line.prefix(6).lowercased()] = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        }
        break
    }
    return table
}()

struct ScanError: LocalizedError {
    let errorDescription: String?
    init(_ why: String) { errorDescription = why }
}

final class Stop {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

enum Mode: String, CaseIterable, Identifiable {
    case off, common, all
    var id: String { rawValue }
    var workers: Int { self == .off ? 64 : self == .common ? 32 : 8 }
}

// Raw values match the keys in settings.json, so saved column choices carry over from the Python version.
enum Field: String, CaseIterable, Identifiable {
    case hostname, ip, host, ping, ports, mac, ipv6_local, ipv6_global, identification, mdns, smb, smb_domain, dns, manufacturer, model, note
    var id: String { rawValue }
    static let names: Set<Field> = [.hostname, .host, .dns, .mdns, .smb, .smb_domain, .model]
    var title: String {
        switch self {
        case .hostname: return "Device"
        case .ip: return "IPv4 Address"
        case .host: return "Hostname"
        case .ping: return "Ping"
        case .ports: return "Open Ports"
        case .mac: return "MAC Address"
        case .ipv6_local: return "IPv6 Local"
        case .ipv6_global: return "IPv6 Global"
        case .identification: return "Identification"
        case .mdns: return "mDNS Name"
        case .smb: return "SMB Name"
        case .smb_domain: return "SMB Domain"
        case .dns: return "DNS Name"
        case .manufacturer: return "Manufacturer"
        case .model: return "Model"
        case .note: return "Note"
        }
    }
}

struct Port: Identifiable, Equatable {
    let port: Int, name: String
    var id: Int { port }
    var label: String { name == "Unknown" ? String(port) : "\(name) \(port)" }
}

// Open ports that speak HTTP(S). shortcut: a fixed list, so a web server on an unlisted port needs "Add New URL…".
let WEB_HTTP: Set<Int> = [80, 3000, 5000, 8080, 8096, 8123, 9090, 32400]
let WEB_HTTPS: Set<Int> = [443, 5001, 8006, 8443, 10000]

extension Device {
    // Not scanned yet: guess the two usual ports rather than show nothing.
    var webURLs: [String] {
        let open = Set(ports.map(\.port))
        let http = portsChecked ? WEB_HTTP.intersection(open) : [80]
        let https = portsChecked ? WEB_HTTPS.intersection(open) : [443]
        return http.sorted().map { "http://\(ip):\($0)" } + https.sorted().map { "https://\(ip):\($0)" }
    }
}

struct V6 { var local = "", global = "" }

struct Found {
    let ip: String, mac: String, ping: Bool, v6: V6
    init(_ ip: String, _ mac: String, _ ping: Bool, _ v6: V6 = V6()) { (self.ip, self.mac, self.ping, self.v6) = (ip, mac, ping, v6) }
}

struct Device: Identifiable {
    var ip: String, mac: String, ping: Bool, ipv6Local: String, ipv6Global: String, vendor: String
    var hostname = "", host = "", dns = "", mdns = "", smb = "", smbDomain = "", model = "", note = ""
    var ports = [Port](), identification = "", kind = ""
    var wait = Set<Field>()  // what's still being looked up, so the UI can show a spinner
    var portsChecked = false  // tells "no open ports" apart from "never looked"
    var id: String { ip }
    var key: String { mac == "?" ? ip : mac }  // favourites follow the MAC, because DHCP can change the IP

    func text(_ f: Field) -> String {
        switch f {
        case .hostname: return hostname
        case .ip: return ip
        case .host: return host
        case .ping: return ping ? "Online" : "No reply"
        case .ports: return ports.map(\.label).joined(separator: ", ")
        case .mac: return mac
        case .ipv6_local: return ipv6Local
        case .ipv6_global: return ipv6Global
        case .identification: return identification
        case .mdns: return mdns
        case .smb: return smb
        case .smb_domain: return smbDomain
        case .dns: return dns
        case .manufacturer: return vendor
        case .model: return model
        case .note: return note
        }
    }
}

enum PortFilter: Hashable { case any, open, closed, port(Int) }

// The drop-downs above the list. nil means "All".
struct Filters: Equatable {
    var kind: String?, vendor: String?, ping: Bool?
    var port = PortFilter.any, favourites = false

    func matches(_ d: Device, favourite: Bool) -> Bool {
        if let kind, d.kind != kind { return false }
        if let vendor, d.vendor != vendor { return false }
        if let ping, d.ping != ping { return false }
        if favourites && !favourite { return false }
        switch port {
        case .any: return true
        case .open: return !d.ports.isEmpty
        case .closed: return d.ports.isEmpty
        case .port(let p): return d.ports.contains { $0.port == p }
        }
    }
}

// What Shodan's InternetDB has seen open on this network's public address.
struct Exposure: Decodable {
    var ports = [Int](), hostnames = [String]()
}

func parseExposure(_ data: Data, status: Int) throws -> Exposure {
    if status == 404 { return Exposure() }  // InternetDB's answer for an address it knows nothing about
    guard status == 200 else { throw ScanError("Shodan answered with error \(status)") }
    var e = try JSONDecoder().decode(Exposure.self, from: data)
    e.ports = Set(e.ports).filter { (1...65535).contains($0) }.sorted()  // off the network: service() traps outside this range
    return e
}

func publicIP(_ s: String) -> String? { ipv4(s).flatMap { isPrivate($0) ? nil : s } }

// MARK: updates

let RELEASES_PAGE = "https://github.com/mayzernator/OtterScan/releases"
let RELEASES_API = "https://api.github.com/repos/mayzernator/OtterScan/releases/latest"
let NEW_ISSUE_PAGE = "https://github.com/mayzernator/OtterScan/issues/new"

/// GitHub's new-issue page with a template to fill in. Carries only what is passed in: nothing about the network or its devices.
func bugReportURL(version: String, build: String, os: String, arch: String) -> URL {
    let body = """
        ## What happened


        ## What you expected


        ## Steps to reproduce
        1.

        ## Environment
        - OtterScan: \(version) (\(build))
        - macOS: \(os)
        - CPU: \(arch)

        """
    var c = URLComponents(string: NEW_ISSUE_PAGE)!
    c.queryItems = [URLQueryItem(name: "title", value: ""), URLQueryItem(name: "body", value: body)]
    c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")  // URLComponents leaves "+", which a web form reads as a space
    return c.url!
}

struct Release: Equatable {
    let version: String
    let page: URL
    var dmg: URL? = nil
}

// GitHub's answer comes off the network, so the page we offer to open must be on our own releases page.
func parseRelease(_ data: Data, status: Int) throws -> Release {
    if status == 404 { throw ScanError("No release has been published yet") }
    guard status == 200 else { throw ScanError("GitHub answered with error \(status)") }
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = j["tag_name"] as? String,
          !versionParts(tag).isEmpty else { throw ScanError("GitHub's answer wasn't a release") }
    let page = (j["html_url"] as? String).flatMap { $0.hasPrefix(RELEASES_PAGE + "/") ? URL(string: $0) : nil }
    let dmg = (j["assets"] as? [[String: Any]])?.lazy.compactMap { $0["browser_download_url"] as? String }
        .first { $0.hasPrefix(RELEASES_PAGE + "/download/") && $0.hasSuffix(".dmg") && URL(string: $0)?.lastPathComponent.hasPrefix("OtterScan") == true }.flatMap { URL(string: $0) }
    return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page ?? URL(string: RELEASES_PAGE + "/latest")!, dmg: dmg)
}

// "v2.1.3" -> [2, 1, 3]. Anything after the digits of a part ("2.1-beta") is ignored.
func versionParts(_ s: String) -> [Int] {
    let s = s.hasPrefix("v") ? String(s.dropFirst()) : s
    var parts = [Int]()
    for piece in s.split(separator: ".", omittingEmptySubsequences: false) {
        guard let n = Int(piece.prefix(while: \.isNumber)) else { break }
        parts.append(n)
    }
    return parts
}

func isNewer(_ latest: String, than current: String) -> Bool {
    let a = versionParts(latest), b = versionParts(current)
    guard !a.isEmpty else { return false }
    for i in 0..<max(a.count, b.count) {
        let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
        if x != y { return x > y }
    }
    return false
}

enum ScanEvent {
    case seen(total: Int, seen: [String: Bool])
    case row(Device)
    case update(Device)
}

// A device (by Device.key) that is in one finished scan pass and not in the other. known: seen before, so not a newcomer.
struct PresenceEvent: Equatable {
    let key: String, joined: Bool, known: Bool
}

func presenceEvents(previous: Set<String>, current: Set<String>, known: Set<String>) -> [PresenceEvent] {
    current.subtracting(previous).sorted().map { PresenceEvent(key: $0, joined: true, known: known.contains($0)) }
        + previous.subtracting(current).sorted().map { PresenceEvent(key: $0, joined: false, known: known.contains($0)) }
}

// MARK: addresses

func ipv4(_ s: String) -> UInt32? {
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? UInt32(bigEndian: a.s_addr) : nil
}

func ipv4(_ n: UInt32) -> String { "\(n >> 24).\(n >> 16 & 255).\(n >> 8 & 255).\(n & 255)" }

struct Net: CustomStringConvertible {
    let base: UInt32, last: UInt32
    let prefix: Int?  // nil for a custom From–To range
    init(_ ip: UInt32, _ prefix: Int) {
        self.prefix = prefix
        base = prefix == 0 ? 0 : ip & (~UInt32(0) << UInt32(32 - prefix))
        last = base + UInt32(truncatingIfNeeded: (1 << (32 - prefix)) - 1)
    }
    init(from: UInt32, to: UInt32) { base = from; last = to; prefix = nil }
    var size: Int { Int(last - base) + 1 }
    var description: String { prefix.map { "\(ipv4(base))/\($0)" } ?? "\(ipv4(base)) – \(ipv4(last))" }
    func contains(_ ip: UInt32) -> Bool { ip >= base && ip <= last }
    var hosts: [UInt32] { if let p = prefix, p < 31 { return Array((base + 1)..<last) }; return Array(base...last) }
}

let privateNets = [("0.0.0.0", 8), ("10.0.0.0", 8), ("127.0.0.0", 8), ("169.254.0.0", 16), ("172.16.0.0", 12),
                   ("192.168.0.0", 16), ("198.18.0.0", 15)].map { Net(ipv4($0.0)!, $0.1) }

func isPrivate(_ ip: UInt32) -> Bool { privateNets.contains { $0.contains(ip) } }

func privateIP(_ s: String) throws -> String {
    guard let ip = ipv4(s), isPrivate(ip) else { throw ScanError("OtterScan only scans private IPv4 addresses") }
    return s
}

func webURL(_ s: String) throws -> URL {
    // browsers read a backslash as a slash, so the host check below would lie
    guard !s.contains("\\"), let c = URLComponents(string: s), c.scheme == "http" || c.scheme == "https", let url = c.url else {
        throw ScanError("only http and https URLs can be opened")
    }
    _ = try privateIP(c.host ?? "")
    return url
}

func parseNet(_ s: String) throws -> Net {
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 2, let ip = ipv4(String(parts[0])), let prefix = parts.count == 2 ? Int(parts[1]) : 32, (0...32).contains(prefix) else {
        throw ScanError("not a valid range: \(s)")
    }
    return try checkedNet(Net(ip, prefix))
}

// Blank From/To mean the first/last host of net; anything else narrows the scan inside it.
func customRange(_ net: Net, _ from: String, _ to: String) throws -> Net {
    let from = from.trimmingCharacters(in: .whitespaces), to = to.trimmingCharacters(in: .whitespaces)
    if from.isEmpty && to.isEmpty { return net }
    let all = Net(from: net.base, to: net.last), h = net.hosts
    guard let lo = from.isEmpty ? h.first : ipv4(from), let hi = to.isEmpty ? h.last : ipv4(to) else { throw ScanError("From and To must be IPv4 addresses") }
    guard all.contains(lo), all.contains(hi) else { throw ScanError("From and To must be inside \(net)") }
    guard lo <= hi else { throw ScanError("From must not be after To") }
    return Net(from: lo, to: hi)
}

func checkedNet(_ net: Net) throws -> Net {
    guard isPrivate(net.base), isPrivate(net.last) else { throw ScanError("OtterScan only scans private IPv4 ranges") }
    guard net.size <= 4096 else { throw ScanError("range too big (max /20)") }
    return net
}

// First match wins. Only names that say what the device is: "Apple" or "Samsung" alone could be anything.
let KINDS: [(String, NSRegularExpression)] = [
    ("printer", "print|epson|brother|canon|laserjet|officejet|deskjet"),
    ("tv", "\\btv|tv\\b|roku|chromecast|bravia|vizio"),
    ("speaker", "homepod|sonos|speaker|\\bbose\\b"),
    ("phone", "iphone|ipad|android|galaxy|pixel"),
    ("computer", "macbook|imac|mac-?(mini|studio|pro)|\\bmac\\b|laptop|desktop|thinkpad|\\bpc\\b"),
    ("server", "server|nas\\b|synology|qnap|raspberry|proxmox"),
    ("router", "router|gateway|modem|unifi|ubiquiti|netgear|eero|mikrotik|arris")
].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: .caseInsensitive)) }

func deviceKind(_ names: String) -> String {  // which symbol to show; "" means no clue
    let all = NSRange(names.startIndex..., in: names)
    return KINDS.first { $0.1.firstMatch(in: names, range: all) != nil }?.0 ?? ""
}

// "Apple, Inc." -> "Apple", "Samsung Electronics Co.,Ltd" -> "Samsung"
let COMPANY_SUFFIX = try! NSRegularExpression(
    pattern: "[\\s,.]+(inc|incorporated|corp|corporation|co|ltd|limited|llc|gmbh|ag|bv|plc|company|technologies|technology|electronics|international)[\\s,.]*$",
    options: .caseInsensitive)

func cleanVendor(_ s: String) -> String {
    var name = s
    while let m = COMPANY_SUFFIX.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let r = Range(m.range, in: name) {
        name.removeSubrange(r)
    }
    return name
}

// Apple's model identifiers ("MacBookPro18,3") start with the product family.
let APPLE_MODELS = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"), ("Macmini", "Mac mini"),
                    ("MacPro", "Mac Pro"), ("iMac", "iMac"), ("Mac", "Mac"), ("iPhone", "iPhone"), ("iPad", "iPad"), ("iPod", "iPod"),
                    ("AppleTV", "Apple TV"), ("AudioAccessory", "HomePod"), ("Watch", "Apple Watch"), ("RealityDevice", "Apple Vision Pro")]

// Marketing names for common identifiers, the way "About This Mac" words them. Anything missing falls back to the family below.
let APPLE_NAMES = [
    "MacBookPro15,1": "MacBook Pro (15-inch, 2018)", "MacBookPro15,2": "MacBook Pro (13-inch, 2018)", "MacBookPro15,3": "MacBook Pro (15-inch, 2019)",
    "MacBookPro15,4": "MacBook Pro (13-inch, 2019)", "MacBookPro16,1": "MacBook Pro (16-inch, 2019)", "MacBookPro16,2": "MacBook Pro (13-inch, 2020)",
    "MacBookPro16,3": "MacBook Pro (13-inch, 2020)", "MacBookPro17,1": "MacBook Pro (13-inch, M1, 2020)",
    "MacBookPro18,1": "MacBook Pro (16-inch, M1 Pro, 2021)", "MacBookPro18,2": "MacBook Pro (16-inch, M1 Max, 2021)",
    "MacBookPro18,3": "MacBook Pro (14-inch, M1 Pro, 2021)", "MacBookPro18,4": "MacBook Pro (14-inch, M1 Max, 2021)",
    "Mac14,7": "MacBook Pro (13-inch, M2, 2022)", "Mac14,5": "MacBook Pro (14-inch, M2 Max, 2023)", "Mac14,9": "MacBook Pro (14-inch, M2 Pro, 2023)",
    "Mac14,6": "MacBook Pro (16-inch, M2 Max, 2023)", "Mac14,10": "MacBook Pro (16-inch, M2 Pro, 2023)",
    "MacBookAir8,1": "MacBook Air (13-inch, 2018)", "MacBookAir8,2": "MacBook Air (13-inch, 2019)", "MacBookAir9,1": "MacBook Air (13-inch, 2020)",
    "MacBookAir10,1": "MacBook Air (M1, 2020)", "Mac14,2": "MacBook Air (M2, 2022)", "Mac14,15": "MacBook Air (15-inch, M2, 2023)",
    "Macmini8,1": "Mac mini (2018)", "Macmini9,1": "Mac mini (M1, 2020)", "Mac14,3": "Mac mini (M2, 2023)", "Mac14,12": "Mac mini (M2 Pro, 2023)",
    "iMac19,1": "iMac (27-inch, 2019)", "iMac20,1": "iMac (27-inch, 2020)", "iMac20,2": "iMac (27-inch, 2020)",
    "iMac21,1": "iMac (24-inch, M1, 2021)", "iMac21,2": "iMac (24-inch, M1, 2021)",
    "Mac13,1": "Mac Studio (M1 Max, 2022)", "Mac13,2": "Mac Studio (M1 Ultra, 2022)", "Mac14,13": "Mac Studio (M2 Max, 2023)",
    "Mac14,14": "Mac Studio (M2 Ultra, 2023)", "MacPro7,1": "Mac Pro (2019)", "Mac14,8": "Mac Pro (2023)",
    "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone13,1": "iPhone 12 mini",
    "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max", "iPhone14,2": "iPhone 13 Pro",
    "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd generation)",
    "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
    "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
    "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
    "AppleTV6,2": "Apple TV 4K (1st generation)", "AppleTV11,1": "Apple TV 4K (2nd generation)", "AppleTV14,1": "Apple TV 4K (3rd generation)",
    "AudioAccessory1,1": "HomePod", "AudioAccessory5,1": "HomePod mini", "AudioAccessory6,1": "HomePod (2nd generation)"]

func friendlyModel(_ id: String) -> String {
    if let name = APPLE_NAMES[id] { return name }
    guard let family = APPLE_MODELS.first(where: { id.hasPrefix($0.0) && id.dropFirst($0.0.count).first?.isNumber == true }) else { return id }
    return "\(family.1) (\(id))"
}

func vendor(_ mac: String) -> String {
    if mac == "?" { return "" }
    if let v = OUI[mac.prefix(8).replacingOccurrences(of: ":", with: "")] { return cleanVendor(v) }
    return (Int(String(mac.dropFirst().prefix(1)), radix: 16) ?? 0) & 2 != 0 ? "Private address" : ""  // locally-administered bit
}

// Device column text: no ".local", hyphens as spaces ("Mays-MacBook-Pro.local" -> "Mays MacBook Pro"). Display only.
func displayName(_ s: String) -> String {
    (s.hasSuffix(".local") ? String(s.dropLast(6)) : s).replacingOccurrences(of: "-", with: " ")
}

func basic(_ f: Found) -> Device {  // what we know instantly; names can take 30s to time out
    let v = vendor(f.mac)
    return Device(ip: f.ip, mac: f.mac, ping: f.ping, ipv6Local: f.v6.local, ipv6Global: f.v6.global, vendor: v, kind: deviceKind(v))
}
