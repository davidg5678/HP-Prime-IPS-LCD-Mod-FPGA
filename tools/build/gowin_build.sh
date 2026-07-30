#!/usr/bin/env bash
# Headless Gowin synthesis + place&route + bitstream generation via gw_sh.
# Usage: tools/build/gowin_build.sh <target-name>   e.g. bringup_selftest
# On success: prints "BUILD PASS: bitstream at impl/pnr/<target>.fs" and exits 0.
# On failure: prints "BUILD FAIL: ..." and exits 1. Full log: impl/<target>_build.log
set -uo pipefail

TARGET="${1:?Usage: gowin_build.sh <target-name>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$ROOT/src/targets/$TARGET"
FILES_TXT="$TDIR/files.txt"
CST="$TDIR/$TARGET.cst"
SDC="$TDIR/$TARGET.sdc"

[ -f "$FILES_TXT" ] || { echo "BUILD FAIL: missing $FILES_TXT"; exit 1; }
[ -f "$CST" ]       || { echo "BUILD FAIL: missing $CST"; exit 1; }
TOP_MODULE="$(tr -d '[:space:]' < "$TDIR/top_module.txt")"

GW_IDE_BIN="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin"
GW_SH="$GW_IDE_BIN/gw_sh"
GW_LIB="$GW_IDE_BIN/../lib"
[ -x "$GW_SH" ] || { echo "BUILD FAIL: gw_sh not found at $GW_SH"; exit 1; }

BUILD_DIR="$ROOT/impl"
mkdir -p "$BUILD_DIR/pnr"
RUN_TCL="$BUILD_DIR/${TARGET}_run.tcl"
{
  echo "set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7"
  echo "add_file \"$CST\""
  [ -f "$SDC" ] && echo "add_file \"$SDC\""
  while IFS= read -r f; do [ -n "$f" ] && echo "add_file \"$ROOT/$f\""; done < "$FILES_TXT"
  echo "set_option -top_module $TOP_MODULE"
  echo "run all"
} > "$RUN_TCL"

# gw_sh's default "impl/" output directory is relative to its CWD, not the .tcl
# script's location — so we run it from $ROOT (not $BUILD_DIR) to avoid a
# doubled-up impl/impl/ nesting. With no project name set, Gowin's default
# output basename is deterministically "project" (project.fs, project.vg, ...).
EXPECTED_FS="$BUILD_DIR/pnr/project.fs"
START_TS=$(date +%s)

echo "==> gw_sh headless build: target=$TARGET top=$TOP_MODULE"
cd "$ROOT"
set +e
DYLD_LIBRARY_PATH="$GW_LIB" DYLD_FRAMEWORK_PATH="$GW_LIB" \
  "$GW_SH" "$RUN_TCL" 2>&1 | tee "$BUILD_DIR/${TARGET}_build.log"
GW_EXIT=${PIPESTATUS[0]}
set -e

if [ "$GW_EXIT" -eq 0 ] && [ -f "$EXPECTED_FS" ]; then
  # Reject a stale bitstream left over from a previous/different run — the
  # file must have been written at or after this invocation started.
  FS_MTIME=$(stat -f %m "$EXPECTED_FS" 2>/dev/null || stat -c %Y "$EXPECTED_FS")
  if [ "$FS_MTIME" -lt "$START_TS" ]; then
    echo "BUILD FAIL: $EXPECTED_FS exists but predates this build (stale artifact) — gw_sh likely failed silently; see $BUILD_DIR/${TARGET}_build.log"
    exit 1
  fi
  cp "$EXPECTED_FS" "$BUILD_DIR/pnr/${TARGET}.fs"
  echo "BUILD PASS: bitstream at $BUILD_DIR/pnr/${TARGET}.fs"
  exit 0
else
  echo "BUILD FAIL: gw_sh_exit=$GW_EXIT expected_bitstream=$EXPECTED_FS (not found); see $BUILD_DIR/${TARGET}_build.log"
  exit 1
fi
