// OtterScan's data types and address helpers. No networking and no UI here.
import Foundation

// Plain names, and also the list the "Common" port scan checks.
let PORTS: [Int: String] = [
    20: "FTP Data", 21: "FTP File Transfer", 22: "SSH Remote Login", 23: "Telnet", 25: "Email (SMTP)",
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
    case hostname, ip, host, ping, ports, mac, ipv6_local, ipv6_global, identification, mdns, smb, smb_domain, dns
    var id: String { rawValue }
    static let names: Set<Field> = [.hostname, .host, .dns, .mdns, .smb, .smb_domain]
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
        }
    }
}

struct Port: Identifiable, Equatable {
    let port: Int, name: String
    var id: Int { port }
    var label: String { name == "Unknown" ? String(port) : "\(name) \(port)" }
}

struct V6 { var local = "", global = "" }

struct Found {
    let ip: String, mac: String, ping: Bool, v6: V6
    init(_ ip: String, _ mac: String, _ ping: Bool, _ v6: V6 = V6()) { (self.ip, self.mac, self.ping, self.v6) = (ip, mac, ping, v6) }
}

struct Device: Identifiable {
    var ip: String, mac: String, ping: Bool, ipv6Local: String, ipv6Global: String, vendor: String
    var hostname = "", host = "", dns = "", mdns = "", smb = "", smbDomain = ""
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
        case .ping: return ping ? "Replied" : "No reply"
        case .ports: return ports.map(\.label).joined(separator: ", ")
        case .mac: return mac
        case .ipv6_local: return ipv6Local
        case .ipv6_global: return ipv6Global
        case .identification: return identification
        case .mdns: return mdns
        case .smb: return smb
        case .smb_domain: return smbDomain
        case .dns: return dns
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

enum ScanEvent {
    case seen(total: Int, seen: [String: Bool])
    case row(Device)
    case update(Device)
}

// MARK: addresses

func ipv4(_ s: String) -> UInt32? {
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? UInt32(bigEndian: a.s_addr) : nil
}

func ipv4(_ n: UInt32) -> String { "\(n >> 24).\(n >> 16 & 255).\(n >> 8 & 255).\(n & 255)" }

struct Net: CustomStringConvertible {
    let base: UInt32, prefix: Int
    init(_ ip: UInt32, _ prefix: Int) {
        self.prefix = prefix
        base = prefix == 0 ? 0 : ip & (~UInt32(0) << UInt32(32 - prefix))
    }
    var size: Int { 1 << (32 - prefix) }
    var last: UInt32 { base + UInt32(size - 1) }
    var description: String { "\(ipv4(base))/\(prefix)" }
    func contains(_ ip: UInt32) -> Bool { ip >= base && ip <= last }
    var hosts: [UInt32] { prefix >= 31 ? Array(base...last) : Array((base + 1)..<last) }
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

func vendor(_ mac: String) -> String {
    if mac == "?" { return "" }
    if let v = OUI[mac.prefix(8).replacingOccurrences(of: ":", with: "")] { return v }
    return (Int(String(mac.dropFirst().prefix(1)), radix: 16) ?? 0) & 2 != 0 ? "Private address" : ""  // locally-administered bit
}

func basic(_ f: Found) -> Device {  // what we know instantly; names can take 30s to time out
    let v = vendor(f.mac)
    return Device(ip: f.ip, mac: f.mac, ping: f.ping, ipv6Local: f.v6.local, ipv6Global: f.v6.global, vendor: v, kind: deviceKind(v))
}
