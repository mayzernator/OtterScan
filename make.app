#!/bin/sh
# One command for a fresh release DMG: wipe old builds, rebuild + test the app, package dist/OtterScan-<version>.dmg.
set -e
cd "$(dirname "$0")"
rm -rf OtterScan.app dist/*.dmg
./build.sh
./make_dmg.sh
