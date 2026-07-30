#!/usr/bin/env bash
# openFPGALoader wrapper. Usage: flash.sh <target> [--persist]
set -euo pipefail
TARGET="${1:?Usage: flash.sh <target> [--persist]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FS="$ROOT/impl/pnr/${TARGET}.fs"
[ -f "$FS" ] || { echo "FLASH FAIL: $FS not found, run tools/build/gowin_build.sh $TARGET first"; exit 1; }
if [ "${2:-}" = "--persist" ]; then
  openFPGALoader -b tangnano20k -f "$FS"
else
  openFPGALoader -b tangnano20k "$FS"
fi
