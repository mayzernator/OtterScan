# otterScan vs Angry IP Scanner: gap analysis

Based on the code at this commit. Angry IP Scanner (ipscan) comparison is from its public feature set, not re-tested.
Effort: S = under a day, M = a few days, L = a week or more.

## Where Angry IP Scanner is ahead (ranked by value / effort)

| # | Gap | Value | Effort | Notes |
|---|-----|-------|--------|-------|
| 1 | Export results (CSV / TXT / XML / JSON) | High | S | Only Print and per-device Copy exist (Views.swift `printList`, `Copy`). Reuse `Field.allCases` + `d.text`. |
| 2 | Scan an arbitrary list of IPs / non-/24 ranges | High | S | Ranges are capped at /20 and private-only (`parseNet`, `checkedNet` in Model.swift). Allow comma lists, and CIDR up to /16. |
| 3 | Custom port list, and TCP port range input | High | S | Port modes are fixed: off / common / all (`Mode` in Model.swift). Add a free-form "22,80,8000-8100" field. |
| 4 | Per-device actions: open in browser, SSH, ping, traceroute | Med | S | Web URLs are handled (`webURL`); no ssh:// or traceroute. |
| 5 | Command-line scan with export | Med | S | `--cli` exists (main.swift) but only prints a table. Add `--csv`/`--json`. |
| 6 | Pluggable "fetchers" (user-chosen columns/data sources) | Med | M | Columns are customizable, but the field set is hard-coded (`Field` enum). Scripts/plugins missing. |
| 7 | Scan non-private / internet ranges | Low | S | Deliberately refused by design; keep it that way unless asked. |
| 8 | Cross-platform (Windows, Linux) | Med | L | otterScan is macOS-only SwiftUI (the old Python GUI still in the repo is not maintained). |
| 9 | Favourite / saved scan configurations | Low | M | Only "Saved ranges" exist (Views.swift). No saved port or filter sets. |

## Where otterScan is already better

| Area | Why it is better | Where in code |
|------|------------------|---------------|
| Live scan with join/leave notifications | Watches the network continuously and posts a macOS notification for new or known devices; clicking opens the device. Angry IP is one-shot. | `passFinished`, `presenceEvents` (ScanModel.swift, Model.swift) |
| Device identification | Combines ARP, mDNS, Bonjour (`_companion-link`, `_airplay`), NetBIOS and a vendor database to name devices and guess the kind (printer, router, server). | Scanner.swift `friendlyName`, `mdnsName`, `nbstat`, `deviceKind` |
| Public exposure check | "Public Ports" view shows what the internet can see of your address via Shodan. Angry IP has nothing like it. | `exposedView`, `checkExposure` |
| Native, modern UI | SwiftUI table, details inspector, search, filters by device kind, dark mode, column customization, printing. Angry IP is a Java/SWT UI. | Views.swift |
| Persistent device memory | Custom names, notes, favourites and per-device URLs survive rescans, keyed by MAC (IP if none). | ScanModel.swift (`names`, `notes`, `favourites`, `urls`) |
| Zero dependencies, small | One tiny binary, no JRE, built with just the Command Line Tools; tests run in the build. | build.sh |
| Safe by default | Private ranges only, size cap, URL validation before opening anything. | `checkedNet`, `webURL` |
| Update check and bug report | Built-in update check and prefilled issue link. | Updates.swift, main.swift |

## Suggested order

1. Export (CSV/JSON) in the app and `--cli`: closes the biggest visible gap for about a day.
2. Custom port list and IP list input.
3. Per-device ssh / traceroute actions.
4. Then decide whether plugins or Windows/Linux are worth the cost. Probably not.
