#!/usr/bin/python3
"""Parser checks. Run: /usr/bin/python3 test_otterscan.py"""
import struct
import otterscan as l

assert l.pad("48:b4:24:84:c:6d") == "48:b4:24:84:0c:6d"
assert l.vendor("?") == ""
assert l.vendor("8a:81:16:75:ee:f8") == "Private address"
assert l.checksum(l.ECHO) == 0

# PTR reply: header, question "x.", answer pointing at question name, rdata "host.local"
q = b"\1x\0" + struct.pack(">HH", 12, 1)
rdata = b"\4host\5local\0"
ans = b"\xc0\x0c" + struct.pack(">HHIH", 12, 1, 120, len(rdata)) + rdata
assert l.parse_ptr(struct.pack(">HHHHHH", 0, 0x8400, 1, 1, 0, 0) + q + ans) == "host.local"

# hostile or broken replies must not raise
assert l.parse_ptr(b"") == ""
assert l.parse_ptr(struct.pack(">HHHHHH", 0, 0, 1, 1, 0, 0) + b"\xff") == ""
loop = struct.pack(">HHHHHH", 0, 0, 1, 1, 0, 0) + q + b"\xc0\x0c" + b"\0" * 10 + b"\xc0\x24"
assert l.parse_ptr(loop) == ""

# NetBIOS: one unique name and one group name
entry = lambda n, flags: n.ljust(15).encode() + b"\0" + struct.pack(">H", flags)
assert l.parse_nbstat(b"\0" * 56 + b"\2" + entry("PC1", 0x0400) + entry("WORK", 0x8400)) == ("PC1", "WORK")
assert l.parse_nbstat(b"") == ("", "")
assert l.parse_nbstat(b"\0" * 56 + b"\5" + b"short") == ("", "")

# plain port names
assert l.service(25565) == "Minecraft"
assert l.service(443) == "Secure Website"
assert l.service(59999) == "Unknown"

# device symbol from names and vendor
assert l.device_kind("Mays-iPhone.local  Apple, Inc.") == "phone"
assert l.device_kind("Mays-MacBook-Pro.local") == "computer"
assert l.device_kind("Mac-mini.lan") == "computer"
assert l.device_kind("DESKTOP-4F2K") == "computer"
assert l.device_kind("Living-Room-TV.local") == "tv"
assert l.device_kind("AppleTV.local") == "tv"
assert l.device_kind("Seiko Epson") == "printer"
assert l.device_kind("Sonos, Inc.") == "speaker"
assert l.device_kind("Synology Incorporated") == "server"
assert l.device_kind("my-nas.lan") == "server"
assert l.device_kind("router.lan") == "router"
assert l.device_kind("Private address") == ""
assert l.device_kind("Apple, Inc.") == ""
assert l.device_kind("") == ""
assert l.basic("10.0.0.1", "?", True, {})["kind"] == ""

# this Mac's own addresses, for pinning its row
assert "127.0.0.1" in l.local_ips()

# port scanner, localhost only: finds what's listening and nothing else
import socket
with socket.socket() as srv:
    srv.bind(("127.0.0.1", 0))
    srv.listen()
    p = srv.getsockname()[1]
    with socket.socket() as spare:  # bound but not listening, so definitely closed
        spare.bind(("127.0.0.1", 0))
        q = spare.getsockname()[1]
        assert l.open_ports("127.0.0.1", [p, q]) == [p]
        assert l.open_ports("127.0.0.1", range(p - 600, min(p + 600, 65536))).count(p) == 1  # spans batches

# live scan: a device joins, one stops pinging then leaves, an IP changes hands. Only new (ip, mac) get looked up.
from itertools import islice
A, B, C = "02:00:00:00:00:0a", "02:00:00:00:00:0b", "02:00:00:00:00:0c"
passes = iter([[("10.0.0.1", A, True, {})],
               [("10.0.0.1", A, False, {}), ("10.0.0.2", B, True, {})],
               [("10.0.0.2", B, True, {})],
               [("10.0.0.2", C, True, {})]])
l.discover = lambda net: next(passes)
l.details = lambda found, mode: ({"ip": f[0]} for f in found)
l.LIVE_PAUSE = 0
m = list(islice(l.events(None, "off", True), 10))
assert m[0] == {"total": 1, "seen": {"10.0.0.1": True}} and m[1]["row"]["ip"] == "10.0.0.1" and m[2] == {"update": {"ip": "10.0.0.1"}}
assert m[3] == {"total": 1, "seen": {"10.0.0.1": False, "10.0.0.2": True}} and m[4]["row"]["ip"] == "10.0.0.2"
assert m[6] == {"total": 0, "seen": {"10.0.0.2": True}}
assert m[7]["total"] == 1 and m[8]["row"]["mac"] == C
# a plain scan is one pass and stops
l.discover = lambda net: [("10.0.0.1", A, True, {})]
assert len(list(l.events(None))) == 3

# Open in Browser: only http(s) to a private IPv4
from otterscan_gui import web_url
assert web_url("https://10.0.0.1:8443/admin") == "https://10.0.0.1:8443/admin"
for bad in ("", "file:///etc/passwd", "ftp://10.0.0.1/", "http://8.8.8.8/", "http://example.com/", "-a", "http://8.8.8.8\\@10.0.0.1/"):
    try:
        web_url(bad)
    except ValueError:
        continue
    raise AssertionError(bad)
print("ok")
