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
# Optional per-target `set_option` lines, sourced verbatim into the generated
# .tcl before the sources are added. Exists because some targets need to
# repurpose dedicated configuration pins as GPIO (see la_capture), and that is
# emphatically not something to switch on globally for every build.
OPTS="$TDIR/options.tcl"

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
  [ -f "$OPTS" ] && cat "$OPTS"
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
  # Timing signoff is part of "did the build pass", not a separate thing to
  # remember to look at. gw_sh exits 0 on a design with violated setup paths and
  # happily writes a bitstream; that bitstream then works at room temperature
  # and fails somewhere colder or hotter. This was not hypothetical -- an
  # la_capture build shipped 15 setup-violated endpoints at Fmax 96.8 MHz
  # against a 108 MHz constraint, printed BUILD PASS, and passed its hardware
  # test anyway. Adding <target>.sdc made the ANALYSIS run; this makes the
  # RESULT gate the build.
  TR="$BUILD_DIR/pnr/project_tr_content.html"
  TIMING=$(python3 - "$TR" <<'PYEOF' 2>/dev/null
import html, re, sys
try:
    t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    print("NOREPORT 0 0 0"); raise SystemExit
t = re.sub(r"<[^>]+>", "|", t)
t = re.sub(r"\s+", " ", html.unescape(t))
def num(label):
    # Cells render as "Numbers of Paths Analyzed| |4191" once tags become '|',
    # so the separator run between label and value mixes bars and spaces.
    m = re.search(re.escape(label) + r"[\s|]*(\d+)", t)
    return int(m.group(1)) if m else -1
paths = num("Numbers of Paths Analyzed")
setup = num("Numbers of Setup Violated Endpoints")
hold  = num("Numbers of Hold Violated Endpoints")
print("OK" if paths >= 0 else "NOREPORT", paths, setup, hold)
PYEOF
)
  set -- $TIMING
  TR_STATE="${1:-NOREPORT}"; TR_PATHS="${2:--1}"; TR_SETUP="${3:--1}"; TR_HOLD="${4:--1}"

  if [ "$TR_STATE" != "OK" ] || [ "$TR_PATHS" -lt 0 ]; then
    echo "BUILD FAIL: no timing report parsed from $TR."
    echo "  Every target needs src/targets/$TARGET/$TARGET.sdc -- without one gw_sh"
    echo "  runs no static timing analysis at all and reports zero violations"
    echo "  because it checked zero paths. See docs/verification.md."
    exit 1
  fi
  if [ "$TR_PATHS" -eq 0 ]; then
    echo "BUILD FAIL: timing analysis covered 0 paths -- the clock constraint in"
    echo "  $SDC is not matching anything. A clean report over no paths is not a signoff."
    exit 1
  fi
  if [ "$TR_SETUP" -ne 0 ] || [ "$TR_HOLD" -ne 0 ]; then
    echo "BUILD FAIL: timing violated -- $TR_SETUP setup and $TR_HOLD hold endpoint(s)"
    echo "  over $TR_PATHS analysed paths. Worst paths are in the Setup Paths Table of"
    echo "  $TR (project.tr.html is only a frameset)."
    exit 1
  fi

  # -f: gw_sh writes output files read-only, so a plain cp can't overwrite a
  # destination left over from a previous build of this target.
  cp -f "$EXPECTED_FS" "$BUILD_DIR/pnr/${TARGET}.fs"
  echo "TIMING PASS: $TR_PATHS paths analysed, 0 setup / 0 hold violations"
  echo "BUILD PASS: bitstream at $BUILD_DIR/pnr/${TARGET}.fs"
  exit 0
else
  echo "BUILD FAIL: gw_sh_exit=$GW_EXIT expected_bitstream=$EXPECTED_FS (not found); see $BUILD_DIR/${TARGET}_build.log"
  exit 1
fi
