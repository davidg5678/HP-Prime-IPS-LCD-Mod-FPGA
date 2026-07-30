#!/usr/bin/env bash
# Fast open-source lint/build sanity check: yosys + nextpnr-himbaechel + apycula.
# Requires oss-cad-suite on PATH (tools/setup/install_tools.sh). This is a
# second-opinion / fast-lint path, NOT the signoff toolchain — see gowin_build.sh.
set -uo pipefail
TARGET="${1:?Usage: oss_cad_build.sh <target-name>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$ROOT/src/targets/$TARGET"
TOP="$(tr -d '[:space:]' < "$TDIR/top_module.txt")"
OUT="$ROOT/build_oss/$TARGET"
mkdir -p "$OUT"

command -v yosys >/dev/null 2>&1 || { echo "OSS BUILD FAIL: yosys not on PATH (see tools/setup/install_tools.sh)"; exit 1; }
command -v nextpnr-himbaechel >/dev/null 2>&1 || { echo "OSS BUILD FAIL: nextpnr-himbaechel not on PATH"; exit 1; }

SOURCES=$(sed "s|^|$ROOT/|" "$TDIR/files.txt" | tr '\n' ' ')

# nextpnr-himbaechel/gowin_pack rewrite the .cst they're given (post-place-and-route
# annotation) — never point them at the source-of-truth file under src/targets/,
# or they'll clobber the pin-number constraints the vendor gw_sh build depends on.
CST_SCRATCH="$OUT/${TARGET}.cst"
cp "$TDIR/$TARGET.cst" "$CST_SCRATCH"

echo "==> yosys synth"
yosys -p "read_verilog -sv $SOURCES; synth_gowin -top $TOP -json $OUT/${TARGET}.json" \
  2>&1 | tee "$OUT/yosys.log"
[ -f "$OUT/${TARGET}.json" ] || { echo "OSS BUILD FAIL: yosys did not produce ${TARGET}.json, see $OUT/yosys.log"; exit 1; }

echo "==> nextpnr-himbaechel place & route"
# --device needs the full part number (speed grade is embedded in it, e.g. the
# "C8" in "QN88C8/I7") — the short "GW2AR-18C" form defaults to an invalid
# speed grade ('ES') and fails. --vopt family=... is separately required for
# the GW2A series (confirmed empirically; not documented in --help).
nextpnr-himbaechel --json "$OUT/${TARGET}.json" --write "$OUT/${TARGET}_routed.json" \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst="$CST_SCRATCH" \
  2>&1 | tee "$OUT/nextpnr.log"
[ -f "$OUT/${TARGET}_routed.json" ] || { echo "OSS BUILD FAIL: nextpnr-himbaechel did not produce routed json, see $OUT/nextpnr.log"; exit 1; }

echo "==> gowin_pack bitstream"
# apycula's device database has no separate "R" (SDRAM-controller) variant —
# GW2AR-18C shares the GW2A-18C fabric database, so -d must drop the "R".
gowin_pack -d GW2A-18C -o "$OUT/${TARGET}.fs" -s "$CST_SCRATCH" "$OUT/${TARGET}_routed.json" \
  2>&1 | tee "$OUT/pack.log"

if [ -f "$OUT/${TARGET}.fs" ]; then
  echo "OSS BUILD PASS: $OUT/${TARGET}.fs"
  exit 0
else
  echo "OSS BUILD FAIL: see $OUT/*.log"
  exit 1
fi
