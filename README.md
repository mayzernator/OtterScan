# OtterScan 🦦

A native macOS app that finds the devices on your local network and the ports they have open.

## Install
### Download (quick)

1. Download **OtterScan-<version>.dmg** from the [latest release](../../releases/latest).
2. Open it and drag **OtterScan** onto **Applications**.
3. First launch only: right-click OtterScan in Applications, choose **Open**, then **Open** again.
   (The app is ad-hoc signed, not notarized. On macOS 15+ you may instead need
   System Settings › Privacy & Security › **Open Anyway**.)

Needs an Apple Silicon Mac on macOS 14.4 or later. Allow Local Network access when asked.

### Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh      # runs the tests, builds OtterScan.app
./make_dmg.sh   # builds dist/OtterScan-<version>.dmg (the drag-to-Applications installer)
```

`make_dmg.sh` drives Finder to lay out the window, so macOS may ask once to let Terminal control Finder.
The blueprint background is drawn by `make_dmg_bg.swift`.

## Keyboard shortcuts
### Scan

⌘ + S - One time scan

⌘ + R - Edit hostname of the selected device

⌘ + L - Live scan

### Tabs

⌘ + 1 - Devices

⌘ + 2 - Ports (local)

⌘ + 3 - Public (ports)

⌘ + ` - Next view

⌘ + B - Hide details
