#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
# Guide never clicks for the user.
! grep -rnE 'AXUIElementPerformAction|kAXPressAction|CGEventPost|\.post\(tap' Sources || { echo "FAIL  Glance must never click"; exit 1; }
swift build -c debug
.build/debug/Glance --selftest
