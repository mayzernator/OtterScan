// Parser and logic checks. build.sh compiles this with Model.swift and Scanner.swift and runs it before building the app.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

check(vendor("?") == "", "unknown mac has no vendor")
check(vendor("8a:81:16:75:ee:f8") == "Private address", "locally administered bit")
check(displayName("Mays-MacBook-Pro.local") == "Mays MacBook Pro", "device name display")
do {
    let a = Net(ipv4("10.0.0.5")!, 24), b = Net(ipv4("192.168.1.5")!, 24)
    var raw = settingRange(a, "10.0.0.10", "10.0.0.20", in: "")
    raw = settingRange(b, "192.168.1.2", "192.168.1.9", in: raw)
    raw = settingRange(a, "10.0.0.11", "10.0.0.30", in: raw)  // replaces a's line, keeps b's
    check(savedRange(a, in: raw)?.from == "10.0.0.11" && savedRange(b, in: raw)?.to == "192.168.1.9", "range per network")
    check(savedRange(Net(ipv4("172.16.0.1")!, 24), in: raw) == nil, "unknown network has no range")
}
check(displayName("192.168.1.5") == "192.168.1.5", "IP left alone")
check(displayName("Mays-iPhone.local.") == "Mays iPhone", "trailing-dot mDNS name")
check(checksum(ECHO) == 0, "ping packet checksum")

// PTR reply: header, question "x.", answer pointing at question name, rdata "host.local"
let question: [UInt8] = [1, 0x78, 0] + header([12, 1])
let rdata: [UInt8] = [4] + Array("host".utf8) + [5] + Array("local".utf8) + [0]
let answer: [UInt8] = [0xc0, 0x0c] + header([12, 1, 0, 120, UInt16(rdata.count)]) + rdata
check(parsePTR(header([0, 0x8400, 1, 1, 0, 0]) + question + answer) == "host.local", "valid PTR reply")

// hostile or broken replies must not crash or hang
check(parsePTR([]) == "", "empty reply")
check(parsePTR(header([0, 0, 1, 1, 0, 0]) + [0xff]) == "", "truncated reply")
let loop = header([0, 0, 1, 1, 0, 0]) + question + [0xc0, 0x0c] + [UInt8](repeating: 0, count: 10) + [0xc0, 0x24]
check(parsePTR(loop) == "", "compression pointer loop")

// NetBIOS: one unique name and one group name
func entry(_ n: String, _ flags: UInt16) -> [UInt8] { Array(n.padding(toLength: 15, withPad: " ", startingAt: 0).utf8) + [0] + header([flags]) }
let nb = [UInt8](repeating: 0, count: 56)
let (nbHost, nbDomain) = parseNbstat(nb + [2] + entry("PC1", 0x0400) + entry("WORK", 0x8400))
check(nbHost == "PC1" && nbDomain == "WORK", "NetBIOS names")
check(parseNbstat([]) == ("", ""), "empty NetBIOS reply")
check(parseNbstat(nb + [5] + Array("short".utf8)) == ("", ""), "truncated NetBIOS reply")

// plain port names
check(service(25565) == "Minecraft", "Minecraft")
check(service(443) == "Secure Website", "HTTPS")
check(service(59999) == "Unknown", "unknown port")

// device symbol from names and vendor
let kinds: [(String, String)] = [
    ("Mays-iPhone.local  Apple, Inc.", "phone"), ("Mays-MacBook-Pro.local", "computer"), ("Mac-mini.lan", "computer"),
    ("DESKTOP-4F2K", "computer"), ("Living-Room-TV.local", "tv"), ("AppleTV.local", "tv"), ("Seiko Epson", "printer"),
    ("Sonos, Inc.", "speaker"), ("Synology Incorporated", "server"), ("my-nas.lan", "server"), ("router.lan", "router"),
    ("Private address", ""), ("Apple, Inc.", ""), ("", "")]
for (names, kind) in kinds { check(deviceKind(names) == kind, "kind of \(names)") }
check(basic(Found("10.0.0.1", "?", true)).kind == "", "no clue, no symbol")

// manufacturer and model
check(cleanVendor("Apple, Inc.") == "Apple" && cleanVendor("Samsung Electronics Co.,Ltd") == "Samsung", "company suffixes dropped")
check(cleanVendor("Seiko Epson") == "Seiko Epson" && cleanVendor("Inc") == "Inc", "real names kept")
check(friendlyModel("Mac99,3") == "Mac (Mac99,3)", "apple model family")
check(friendlyModel("MacBookPro18,4") == "MacBook Pro (14-inch, M1 Max, 2021)" && friendlyModel("iPhone14,2") == "iPhone 13 Pro", "marketing names")
check(friendlyModel("MacBookPro99,9") == "MacBook Pro (MacBookPro99,9)", "unknown Apple model keeps its family")
check(friendlyModel("iPhone99,1").hasPrefix("iPhone (") && friendlyModel("AppleTV99,1").hasPrefix("Apple TV"), "iPhone and Apple TV")
check(friendlyModel("Chromecast") == "Chromecast" && friendlyModel("MacBookish") == "MacBookish", "other models unchanged")
let txt = "model=Mac14,3"
let reply: [UInt8] = header([0, 0x8400, 0, 1, 0, 0]) + [1, 0x78, 0] + header([16, 1, 0, 0, UInt16(txt.utf8.count + 1)]) + [UInt8(txt.utf8.count)] + Array(txt.utf8)
check(parseTXT(reply) == ["model": "Mac14,3"], "TXT record read")
check(parseTXT(Array(reply.prefix(30))).isEmpty && parseTXT([]).isEmpty, "truncated reply tolerated")

// this Mac's own addresses, for pinning its row
check(localIPs().contains("127.0.0.1"), "loopback is listed")

// addresses and ranges
check(ipv4("10.0.0.1") == 0x0a000001 && ipv4(0x0a000001) == "10.0.0.1" && ipv4("10.0.0") == nil, "ipv4 round trip")
check((try? parseNet("192.168.1.77/24"))?.description == "192.168.1.0/24", "range rounds down to its network")
check((try? parseNet("10.0.0.0/20")) != nil, "a /20 is the biggest allowed")
let lan = Net(ipv4("10.0.0.0")!, 24)
check((try? customRange(lan, "10.0.0.5", "10.0.0.9"))?.hosts.count == 5, "From/To narrows the scan")
check((try? customRange(lan, "", ""))?.description == "10.0.0.0/24", "blank From/To keeps the whole subnet")
check((try? customRange(lan, "10.0.1.5", ""))  == nil && (try? customRange(lan, "10.0.0.9", "10.0.0.5")) == nil, "rejects out-of-subnet and reversed ranges")
for bad in ["10.0.0.0/19", "8.8.8.0/24", "nonsense", "10.0.0.0/33", "10.0.0.0/8"] { check((try? parseNet(bad)) == nil, "rejects range \(bad)") }
check(Net(ipv4("10.0.0.0")!, 30).hosts == [0x0a000001, 0x0a000002], "hosts leave out network and broadcast")

// port scanner, localhost only: finds what's listening and nothing else
func listener() -> (fd: Int32, port: Int) {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var a = inet("127.0.0.1", 0)
    _ = withAddr(&a) { bind(s, $0, $1) }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withAddr(&a) { p, _ in getsockname(s, p, &len) }
    return (s, Int(UInt16(bigEndian: a.sin_port)))
}
prepareProcess()
let open = listener(), spare = listener()  // spare is bound but never listens, so it's closed
listen(open.fd, 5)
check((try? openPorts("127.0.0.1", [open.port, spare.port])) == [open.port], "finds only the listening port")
let lo = max(1, open.port - 600), hi = min(open.port + 600, 65535)
check((try? openPorts("127.0.0.1", Array(lo...hi)))?.filter { $0 == open.port }.count == 1, "spans batches")
// a port listening that answers HTTP gets its Server header read
check(serverHeader(Array("HTTP/1.0 200 OK\r\nServer: nginx/1.2\r\n\r\n".utf8)) == "nginx/1.2", "Server header")
check(serverHeader(Array("HTTP/1.0 200 OK\r\n\r\n".utf8)) == nil, "no Server header")

// live scan: a device joins, one stops pinging then leaves, an IP changes hands. Only new (ip, mac) get looked up.
let A = "02:00:00:00:00:0a", B = "02:00:00:00:00:0b", C = "02:00:00:00:00:0c"
var passes = [[Found("10.0.0.1", A, true)],
              [Found("10.0.0.1", A, false), Found("10.0.0.2", B, true)],
              [Found("10.0.0.2", B, true)],
              [Found("10.0.0.2", C, true)]]
let stop = Stop()
var log = [ScanEvent]()
let net = Net(ipv4("10.0.0.0")!, 24)
try events(net, .off, live: true, stop: stop, pause: 0, find: { _ in passes.removeFirst() },
           lookup: { found, _, _, emit in for f in found { emit(basic(f)) } },
           emit: { log.append($0); if log.count == 10 { stop.set() } })
func tag(_ e: ScanEvent) -> String {
    switch e {
    case .seen(let t, let s): return "seen \(t) \(s.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
    case .row(let d): return "row \(d.ip)"
    case .update(let d): return "update \(d.ip)"
    }
}
check(log.map(tag) == ["seen 1 10.0.0.1=true", "row 10.0.0.1", "update 10.0.0.1",
                       "seen 1 10.0.0.1=false,10.0.0.2=true", "row 10.0.0.2", "update 10.0.0.2",
                       "seen 0 10.0.0.2=true",
                       "seen 1 10.0.0.2=true", "row 10.0.0.2", "update 10.0.0.2"], "live scan events: \(log.map(tag))")
if case .row(let d) = log[8] { check(d.mac == C, "a reassigned IP counts as new") }
// a plain scan is one pass and stops
var plain = [ScanEvent]()
try events(net, find: { _ in [Found("10.0.0.1", A, true)] }, lookup: { f, _, _, emit in for x in f { emit(basic(x)) } }, emit: { plain.append($0) })
check(plain.count == 3, "plain scan is one pass")

// notifications: who joined and who left between two passes, and whether we had seen them before
check(presenceEvents(previous: [A, B], current: [B, C, "10.0.0.9"], known: [A, B, "10.0.0.9"]) == [
    PresenceEvent(key: C, joined: true, known: false), PresenceEvent(key: "10.0.0.9", joined: true, known: true),
    PresenceEvent(key: A, joined: false, known: true)], "joined and left devices")
check(presenceEvents(previous: [A], current: [A], known: []).isEmpty, "nothing changed, nothing to say")

// Open in Browser: only http(s) to a private IPv4
check((try? webURL("https://10.0.0.1:8443/admin"))?.absoluteString == "https://10.0.0.1:8443/admin", "private https url")
for bad in ["", "file:///etc/passwd", "ftp://10.0.0.1/", "http://8.8.8.8/", "http://example.com/", "-a", "http://8.8.8.8\\@10.0.0.1/"] {
    check((try? webURL(bad)) == nil, "rejects url \(bad)")
}

// an unknown port is labelled by its number alone
check(Port(port: 59999, name: "Unknown").label == "59999", "unknown port label")
check(Port(port: 22, name: "SSH").label == "SSH 22", "named port label")

// drop-down filters
var d1 = basic(Found("10.0.0.5", A, true))
d1.kind = "printer"; d1.vendor = "Epson"; d1.ports = [Port(port: 631, name: "Printer (IPP)")]
let d2 = basic(Found("10.0.0.6", "?", false))
check(d1.key == A && d2.key == "10.0.0.6", "favourites key on MAC, or IP without one")
check(Filters().matches(d1, favourite: false) && Filters().matches(d2, favourite: false), "no filters match everything")
var f = Filters(); f.kind = "printer"
check(f.matches(d1, favourite: false) && !f.matches(d2, favourite: false), "type filter")
f = Filters(); f.kind = ""
check(!f.matches(d1, favourite: false) && f.matches(d2, favourite: false), "Unknown type is a real choice, not All")
f = Filters(); f.vendor = "Epson"
check(f.matches(d1, favourite: false) && !f.matches(d2, favourite: false), "vendor filter")
f = Filters(); f.ping = false
check(!f.matches(d1, favourite: false) && f.matches(d2, favourite: false), "ping filter")
f = Filters(); f.favourites = true
check(f.matches(d1, favourite: true) && !f.matches(d1, favourite: false), "favourites filter")
for (p, a, b) in [(PortFilter.open, true, false), (.closed, false, true), (.port(631), true, false), (.port(22), false, false)] {
    f = Filters(); f.port = p
    check(f.matches(d1, favourite: false) == a && f.matches(d2, favourite: false) == b, "port filter \(p)")
}

// Shodan's replies come off the network too
let shodan = Data(#"{"ip":"1.2.3.4","ports":[443,22,22,70000,0],"hostnames":["a.example"],"cpes":[],"tags":[],"vulns":[]}"#.utf8)
check((try? parseExposure(shodan, status: 200))?.ports == [22, 443], "exposure ports are sorted, unique and in range")
check((try? parseExposure(Data(), status: 404))?.ports == [], "404 means nothing known")
check((try? parseExposure(shodan, status: 500)) == nil, "server error")
check((try? parseExposure(Data("nope".utf8), status: 200)) == nil, "garbage reply")
check(publicIP("8.8.8.8") == "8.8.8.8" && publicIP("192.168.1.1") == nil && publicIP("1.1.1.1/../x") == nil, "public address check")

// update check: version order, and GitHub's reply comes off the network too
check(isNewer("v2.1", than: "2.0") && isNewer("2.10", than: "2.9") && isNewer("2.0.1", than: "2.0"), "newer versions")
check(!isNewer("2.0", than: "2.0") && !isNewer("v2.0.0", than: "2.0") && !isNewer("1.9", than: "2.0"), "same or older versions")
check(!isNewer("nightly", than: "2.0") && !isNewer("", than: "2.0"), "a tag that isn't a version is never an update")
check(versionParts("v2.1-beta") == [2, 1] && versionParts("2..1") == [2], "odd version strings")
let ownPage = RELEASES_PAGE + "/tag/v2.1"
let release = Data(#"{"tag_name":"v2.1","html_url":"\#(ownPage)"}"#.utf8)
check((try? parseRelease(release, status: 200)) == Release(version: "2.1", page: URL(string: ownPage)!), "release reply")
let elsewhere = Data(#"{"tag_name":"v2.1","html_url":"https://evil.example/download"}"#.utf8)
let withDmg = Data(#"{"tag_name":"v2.2","assets":[{"browser_download_url":"https://evil.example/OtterScan.dmg"},{"browser_download_url":"\#(RELEASES_PAGE)/download/v2.2/OtterScan.dmg"}]}"#.utf8)
check((try? parseRelease(withDmg, status: 200))?.dmg?.absoluteString == RELEASES_PAGE + "/download/v2.2/OtterScan.dmg", "dmg asset on our own releases only")
let versioned = Data(#"{"tag_name":"v2.4.3","assets":[{"browser_download_url":"\#(RELEASES_PAGE)/download/v2.4.3/OtterScan-2.4.3.dmg"}]}"#.utf8)
check((try? parseRelease(versioned, status: 200))?.dmg?.lastPathComponent == "OtterScan-2.4.3.dmg", "versioned dmg name is found")
check((try? parseRelease(elsewhere, status: 200))?.page.absoluteString == RELEASES_PAGE + "/latest", "foreign link is not offered")
check((try? parseRelease(Data(#"{"tag_name":"nightly"}"#.utf8), status: 200)) == nil, "tag without a version")
check((try? parseRelease(Data("nope".utf8), status: 200)) == nil && (try? parseRelease(release, status: 403)) == nil, "bad reply")

// bug report: opens GitHub's new-issue page carrying the environment and nothing else
let bug = bugReportURL(version: "2.1+beta", build: "42", os: "Version 15.1 (Build 24B83) & more", arch: "arm64")
let bugBody = URLComponents(url: bug, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? ""
check(bug.scheme == "https" && bug.host == "github.com" && bug.path == "/mayzernator/OtterScan/issues/new", "bug report page")
check(bugBody.contains("- OtterScan: 2.1+beta (42)\n- macOS: Version 15.1 (Build 24B83) & more\n- CPU: arm64\n"), "bug report environment survives the URL")
check(!bug.absoluteString.contains("+") && bug.absoluteString.components(separatedBy: "&").count == 2, "bug report body is fully encoded")
check(["## What happened", "## What you expected", "## Steps to reproduce", "## Environment"].allSatisfy(bugBody.contains), "bug report headings")

// reading the kernel's neighbor tables must not crash, whatever they hold
_ = arpTable(); _ = ndpTable()

if failures == 0 { print("ok") } else { print("\(failures) check(s) failed"); exit(1) }
