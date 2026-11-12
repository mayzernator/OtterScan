#!/bin/sh
# Builds OtterScan.app next to this script. Needs only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
TARGET=arm64-apple-macos14.4
SRC="Model.swift Scanner.swift"
swiftc -O -swift-version 5 $SRC Tests/main.swift -o "$TMPDIR/otterscan-tests"
"$TMPDIR/otterscan-tests"
rm -rf OtterScan.app
mkdir -p OtterScan.app/Contents/MacOS OtterScan.app/Contents/Resources
swiftc -O -swift-version 5 $SWIFTFLAGS -target $TARGET $SRC ScanModel.swift Views.swift Updates.swift main.swift -o OtterScan.app/Contents/MacOS/OtterScan
I="$TMPDIR/AppIcon.iconset"; rm -rf "$I"; mkdir "$I"
cp logo/otter-globe/app-icon.png "$I/icon_512x512@2x.png"
for s in 16 32 64 128 256 512; do sips -z $s $s "$I/icon_512x512@2x.png" --out "$I/icon_${s}x${s}.png" >/dev/null; done
for s in 16 32 128 256; do cp "$I/icon_$((s*2))x$((s*2)).png" "$I/icon_${s}x${s}@2x.png"; done
cp "$I/icon_64x64.png" "$I/icon_32x32@2x.png"; rm "$I/icon_64x64.png"
iconutil -c icns "$I" -o OtterScan.app/Contents/Resources/AppIcon.icns
cat > OtterScan.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>OtterScan</string>
<key>CFBundleDisplayName</key><string>OtterScan</string>
<key>CFBundleIdentifier</key><string>local.otterscan.app</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>OtterScan</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.5.1</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>OtterScan looks for devices on your local network.</string>
<key>NSAppTransportSecurity</key><dict>
<key>NSAllowsLocalNetworking</key><true/>
<key>NSExceptionDomains</key><dict><key>ip-api.com</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict></dict>
</dict>
</dict></plist>
EOF
# iCloud Drive keeps re-tagging the bundle folder and codesign rejects that, so sign a copy outside it
S="$TMPDIR/OtterScan-sign"; rm -rf "$S"; mkdir "$S"
ditto --noextattr --norsrc OtterScan.app "$S/OtterScan.app"
codesign --force --deep -s - "$S/OtterScan.app"
rm -rf OtterScan.app
ditto "$S/OtterScan.app" OtterScan.app
echo built OtterScan.app
