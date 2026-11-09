#!/bin/sh
# Builds dist/OtterScan.dmg: the drag-to-Applications installer. Needs only Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
[ -d OtterScan.app ] || ./build.sh
T="$(mktemp -d)"; trap 'hdiutil detach "/Volumes/OtterScan" -quiet 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p dist "$T/src/.background"
swiftc -O make_dmg_bg.swift -o "$T/bg"
"$T/bg" otter.svg "$T/src/.background/bg.png"
ditto --noextattr --norsrc OtterScan.app "$T/src/OtterScan.app"
ln -s /Applications "$T/src/Applications"
hdiutil detach /Volumes/OtterScan -quiet 2>/dev/null || true
hdiutil create -srcfolder "$T/src" -volname OtterScan -fs HFS+ -format UDRW -ov "$T/rw.dmg" -quiet
hdiutil attach "$T/rw.dmg" -mountpoint /Volumes/OtterScan -noautoopen -quiet
# Finder lays out the window: background, icon size and positions (needs a one-time Automation OK for Terminal)
osascript <<'EOF'
tell application "Finder"
  tell disk "OtterScan"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to (POSIX file "/Volumes/OtterScan/.background/bg.png")
    set position of item "OtterScan.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
sync
hdiutil detach /Volumes/OtterScan -quiet
rm -f dist/OtterScan.dmg
hdiutil convert "$T/rw.dmg" -format UDZO -imagekey zlib-level=9 -o dist/OtterScan.dmg -quiet
echo built dist/OtterScan.dmg
