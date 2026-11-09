#!/bin/sh
# OtterScan's scanner. Keep this window open while the app runs; it closes itself when you quit OtterScan.
printf '\033]0;OtterScan Scanner\007'
cd "$(dirname "$0")" || exit 1
# -B: writing __pycache__ into the bundle would break its code signature
/usr/bin/python3 -B -u otterscan_gui.py --app
# Backgrounded and delayed so Terminal sees no running process and doesn't ask before closing.
nohup sh -c "sleep 1; osascript -e 'tell application \"Terminal\" to close (every window whose name contains \"OtterScan Scanner\") saving no'" >/dev/null 2>&1 &
