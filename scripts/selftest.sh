#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug
.build/debug/Glance --selftest
