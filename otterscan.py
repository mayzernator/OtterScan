#!/usr/bin/python3
"""OtterScan: find devices on your local network. Stdlib only, macOS.

Usage: /usr/bin/python3 otterscan.py [CIDR] [--ports | --all-ports]   (default: your subnet)
"""
import errno, ipaddress, os, re, resource, select, selectors, socket, struct, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed

# Plain names, and also the list the "Common" port scan checks.
PORTS = {
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
    27015: "Steam Game Server", 27017: "MongoDB Database", 32400: "Plex Media", 62078: "iPhone Sync"}
_services_lock = threading.Lock()  # getservbyport returns a shared static buffer
OUI_FILES = ["/opt/homebrew/share/nmap/nmap-mac-prefixes", "/usr/share/nmap/nmap-mac-prefixes"]
OUI = {}
for f in OUI_FILES:
    if os.path.exists(f):
        for line in open(f, encoding="utf-8", errors="ignore"):
            if line[:1] != "#" and len(line) > 7:
                OUI[line[:6].lower()] = line[7:].strip()
        break

# macOS defaults to 256 open files; a port scan holds far more sockets than that
_soft, _hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (8192 if _hard == resource.RLIM_INFINITY else min(8192, _hard), _hard))


def local_net():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))  # UDP connect sends nothing; just picks the route
    ip = s.getsockname()[0]
    s.close()
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    m = re.search(rf"inet {re.escape(ip)} netmask (0x[0-9a-f]+)", out)  # macOS prints hex masks
    return ipaddress.ip_network(f"{ip}/{bin(int(m[1], 16)).count('1') if m else 24}", strict=False)


def local_ips():  # every interface, so scanning a second attached network still finds this Mac
    return re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)", subprocess.run(["ifconfig"], capture_output=True, text=True).stdout)


def checksum(b):
    s = sum(struct.unpack(f"!{len(b) // 2}H", b))
    s = (s >> 16) + (s & 0xffff)
    return ~(s + (s >> 16)) & 0xffff


ECHO = struct.pack("!BBHHH", 8, 0, checksum(struct.pack("!BBHHH", 8, 0, 0, 0x4c53, 1)), 0x4c53, 1)


def sweep(net):
    """Ping every host from one socket. One socket, not a `ping` process each:
    forking thousands of times from threads is what segfaulted the app."""
    up = set()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP) as s:
        s.setblocking(False)

        def drain(wait):
            while select.select([s], [], [], wait)[0]:
                wait = 0
                try:
                    data, addr = s.recvfrom(1500)
                except OSError:
                    continue
                # shortcut: macOS includes the IP header in replies, Linux would need offset 0
                if data[20:21] == b"\0":
                    up.add(addr[0])

        for _ in range(2):  # second pass catches hosts whose ARP entry wasn't ready
            for i, ip in enumerate(net.hosts()):
                try:
                    s.sendto(ECHO, (str(ip), 0))
                except OSError as e:  # empty addresses fail instantly; only a full queue needs a pause
                    if e.errno == errno.ENOBUFS:
                        drain(.01)
                if i % 64 == 63:
                    drain(.05)
        end = time.time() + 1.5
        while time.time() < end:
            drain(.1)
    return up


def pad(mac):  # macOS drops leading zeros in MAC octets
    return ":".join(o.zfill(2) for o in mac.split(":"))


def arp_table():
    out = subprocess.run(["/usr/sbin/arp", "-an"], capture_output=True, text=True).stdout
    return {ip: pad(mac) for ip, mac in re.findall(
        r"\((\d+\.\d+\.\d+\.\d+)\) at ((?:[0-9a-f]{1,2}:){5}[0-9a-f]{1,2})", out)}


def ndp_table():
    """MAC -> {'local': ipv6, 'global': ipv6}"""
    out = subprocess.run(["/usr/sbin/ndp", "-an"], capture_output=True, text=True).stdout
    t = {}
    for ip6, mac in re.findall(r"^(\S+?)(?:%\S+)?\s+((?:[0-9a-f]{1,2}:){5}[0-9a-f]{1,2})", out, re.M):
        kind = "local" if ip6.lower().startswith("fe80") else "global"
        t.setdefault(pad(mac), {}).setdefault(kind, ip6)
    return t


def vendor(mac):
    if mac == "?":
        return ""
    v = OUI.get(mac[:8].replace(":", ""))
    if v:
        return v
    return "Private address" if int(mac[1], 16) & 2 else ""  # locally-administered bit


def udp(ip, port, pkt):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(1)
        for _ in range(2):  # UDP gets dropped when dozens of queries go out at once
            try:
                s.sendto(pkt, (ip, port))
                return s.recvfrom(2048)[0]
            except OSError:
                pass
        return b""


def dns_name(ip):  # full reverse-DNS name via the system resolver
    try:  # getnameinfo, not gethostbyaddr: Python holds a global lock around that one on macOS
        return socket.getnameinfo((ip, 0), socket.NI_NAMEREQD)[0]
    except OSError:
        return ""


def read_name(msg, i):
    parts = []
    while i < len(msg):
        n = msg[i]
        if n == 0:
            return ".".join(parts)
        if n & 0xC0 == 0xC0:  # compression pointer
            return ".".join(parts + [read_name(msg, ((n & 0x3F) << 8) | msg[i + 1])])
        parts.append(msg[i + 1:i + 1 + n].decode(errors="replace"))
        i += n + 1
    return ".".join(parts)


def parse_ptr(r):
    """First PTR answer in a DNS reply, or ''. Replies come off the network, so tolerate garbage."""
    try:
        if len(r) > 12 and struct.unpack(">H", r[6:8])[0]:
            i = 12
            while r[i]:
                i += r[i] + 1
            i += 5  # name end + qtype + qclass
            while r[i] & 0xC0 != 0xC0 and r[i]:  # skip answer name
                i += r[i] + 1
            i += 2 if r[i] & 0xC0 == 0xC0 else 1
            return read_name(r, i + 10)  # skip type, class, ttl, rdlen
    except (IndexError, RecursionError):  # truncated reply or pointer loop
        pass
    return ""


def mdns_name(ip):  # ask the device itself for its .local name (unicast mDNS)
    q = b"".join(bytes([len(p)]) + p.encode() for p in ip.split(".")[::-1] + ["in-addr", "arpa"]) + b"\0"
    return parse_ptr(udp(ip, 5353, struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + q + struct.pack(">HH", 12, 1)))


def parse_nbstat(r):
    """NetBIOS node status reply -> (host name, workgroup/domain)"""
    host = domain = ""
    try:
        for k in range(r[56]):
            e = r[57 + 18 * k:57 + 18 * (k + 1)]
            name, suffix, flags = e[:15].decode(errors="replace").strip(), e[15], struct.unpack(">H", e[16:18])[0]
            if suffix == 0 and flags & 0x8000:
                domain = domain or name
            elif suffix == 0:
                host = host or name
    except (IndexError, struct.error):
        pass
    return host, domain


def smb_names(ip):
    pkt = struct.pack(">HHHHHH", 1, 0, 1, 0, 0, 0) + b"\x20" + b"CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" + b"\0" + struct.pack(">HH", 0x21, 1)
    return parse_nbstat(udp(ip, 137, pkt))


def service(p):
    if p in PORTS:
        return PORTS[p]
    try:
        with _services_lock:
            return socket.getservbyport(p, "tcp").replace("-", " ").title()
    except OSError:
        return "Unknown"


BATCH = 512  # sockets open at once per device; 8 devices at a time stays under the 8192 file limit


def open_ports(ip, ports, stop=None):
    """Connect-scan `ports` on one device with non-blocking sockets. Returns the open ones, sorted."""
    ports, found = list(ports), []
    with selectors.DefaultSelector() as sel:  # kqueue; select() can't handle fds above 1024
        for start in range(0, len(ports), BATCH):
            if stop and stop.is_set():
                break
            pending = 0
            for p in ports[start:start + BATCH]:
                s = socket.socket()
                s.setblocking(False)
                rc = s.connect_ex((ip, p))
                if rc == errno.EINPROGRESS:
                    sel.register(s, selectors.EVENT_WRITE, p)
                    pending += 1
                else:
                    if rc == 0:
                        found.append(p)
                    s.close()
            end = time.time() + 0.4
            while pending and time.time() < end:
                for key, _ in sel.select(max(0, end - time.time())):
                    if key.fileobj.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0:
                        found.append(key.data)
                    sel.unregister(key.fileobj)
                    key.fileobj.close()
                    pending -= 1
            for key in list(sel.get_map().values()):  # filtered ports never answer
                sel.unregister(key.fileobj)
                key.fileobj.close()
    return sorted(found)


def identify(ip, ports):  # HTTP "Server" header as a cheap fingerprint
    for p in (80, 8080):
        if p in ports:
            try:
                with socket.create_connection((ip, p), 1) as s:
                    s.settimeout(1)
                    s.sendall(b"HEAD / HTTP/1.0\r\nHost: x\r\n\r\n")
                    m = re.search(rb"(?i)^server:\s*(.+?)\r?$", s.recv(2048), re.M)
                    if m:
                        return m[1].decode(errors="replace")
            except OSError:
                pass
    return ""


def port_info(ip, mode="common", stop=None):
    ports = open_ports(ip, range(1, 65536) if mode == "all" else PORTS, stop)
    return {"ports": [{"port": p, "name": service(p)} for p in ports], "identification": identify(ip, ports)}


# First match wins. Only names that say what the device is: "Apple" or "Samsung" alone could be anything.
KINDS = [("printer", r"print|epson|brother|canon|laserjet|officejet|deskjet"),
         ("tv", r"\btv|tv\b|roku|chromecast|bravia|vizio"),
         ("speaker", r"homepod|sonos|speaker|\bbose\b"),
         ("phone", r"iphone|ipad|android|galaxy|pixel"),
         ("computer", r"macbook|imac|mac-?(mini|studio|pro)|\bmac\b|laptop|desktop|thinkpad|\bpc\b"),
         ("server", r"server|nas\b|synology|qnap|raspberry|proxmox"),
         ("router", r"router|gateway|modem|unifi|ubiquiti|netgear|eero|mikrotik|arris")]


def device_kind(names):  # which symbol to show; "" means no clue
    return next((k for k, p in KINDS if re.search(p, names, re.I)), "")


def basic(ip, mac, pings, v6):  # what we know instantly; names can take 30s to time out
    return {"ip": ip, "ipv6_local": v6.get("local", ""), "ipv6_global": v6.get("global", ""),
            "mac": mac, "hostname": "", "host": "", "ping": pings, "vendor": vendor(mac), "dns": "", "mdns": "",
            "smb": "", "smb_domain": "", "ports": [], "identification": "", "kind": device_kind(vendor(mac))}


def detail(ip, mac, pings, v6, mode, stop):
    dns, mdns = dns_name(ip), mdns_name(ip)
    smb, dom = smb_names(ip)
    name = dns or mdns or smb
    return {**basic(ip, mac, pings, v6), "hostname": name, "host": name, "dns": dns, "mdns": mdns,
            "smb": smb, "smb_domain": dom, "kind": device_kind(f"{dns} {mdns} {smb} {vendor(mac)}"),
            **(port_info(ip, mode, stop) if mode != "off" else {})}


def discover(net):
    """Every device on net, as (ip, mac, answered_ping, ipv6)."""
    up = sweep(net)
    arp = arp_table()
    ndp = ndp_table()
    ips = up | {ip for ip, mac in arp.items()  # firewalled hosts ignore ping but still ARP
                if ipaddress.ip_address(ip) in net and mac != "ff:ff:ff:ff:ff:ff"}
    return [(ip, arp.get(ip, "?"), ip in up, ndp.get(arp.get(ip), {}))
            for ip in sorted(ips, key=ipaddress.ip_address)]


def details(found, mode="off"):
    """Yield one row per device as each finishes. Closing the generator cancels the rest."""
    ex = ThreadPoolExecutor({"off": 64, "common": 32, "all": 8}[mode])
    stop = threading.Event()
    try:
        for fut in as_completed([ex.submit(detail, *f, mode, stop) for f in found]):
            yield fut.result()
    finally:
        stop.set()
        ex.shutdown(wait=False, cancel_futures=True)


LIVE_PAUSE = 5  # seconds between live passes; each pass pings the whole range


def events(net, mode="off", live=False):
    """The scan as messages for the UI. Live repeats until closed, looking up only new devices."""
    known = set()
    while True:
        found = discover(net)
        new = [f for f in found if f[:2] not in known]  # (ip, mac): a reassigned IP counts as new
        known = {f[:2] for f in found}
        yield {"total": len(new), "seen": {f[0]: f[2] for f in found}}  # also how Stop is noticed: a write fails
        for f in new:
            yield {"row": basic(*f)}
        for row in details(new, mode):
            yield {"update": row}
        if not live:
            return
        time.sleep(LIVE_PAUSE)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    net = ipaddress.ip_network(args[0], strict=False) if args else local_net()
    print(f"Scanning {net} ...")
    mode = "all" if "--all-ports" in sys.argv else "common" if "--ports" in sys.argv else "off"
    for d in sorted(details(discover(net), mode), key=lambda d: ipaddress.ip_address(d["ip"])):
        ports = ", ".join(f"{p['name']} {p['port']}" for p in d["ports"])
        print(f"{d['ip']:<16}{d['mac']:<19}{d['hostname']:<42}{d['vendor']:<30}{ports}")
