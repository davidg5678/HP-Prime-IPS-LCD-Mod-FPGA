#!/usr/bin/env bash
# Compile + run a self-checking testbench with Icarus Verilog; PASS/FAIL for agent consumption.
# Usage: tools/sim/run_sim.sh <sim-target-name>   e.g. bringup_uart_loopback
set -uo pipefail
TARGET="${1:?Usage: run_sim.sh <sim-target-name>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$ROOT/sim/targets/$TARGET"
FILES_TXT="$TDIR/files.txt"

[ -f "$FILES_TXT" ] || { echo "SIM FAIL: missing $FILES_TXT"; exit 1; }
TOP="$(tr -d '[:space:]' < "$TDIR/top_module.txt")"

mkdir -p "$ROOT/sim/.build"
VVP_OUT="$ROOT/sim/.build/${TARGET}.vvp"
SOURCES=$(sed "s|^|$ROOT/|" "$FILES_TXT")

echo "==> Lint (verilator, informational — does not gate pass/fail)"
if command -v verilator >/dev/null 2>&1; then
    verilator --lint-only -Wall $SOURCES 2>&1 || true
else
    echo "(verilator not on PATH, skipping lint)"
fi

echo "==> Compiling $TARGET (top=$TOP)"
if ! iverilog -g2012 -o "$VVP_OUT" -s "$TOP" $SOURCES; then
    echo "SIM FAIL: compilation error (see above)"
    exit 1
fi

echo "==> Running $TARGET"
LOG="$ROOT/sim/.build/${TARGET}.log"
vvp "$VVP_OUT" | tee "$LOG"

if grep -q "^PASS:" "$LOG" && ! grep -q "^FAIL:" "$LOG"; then
    exit 0
else
    echo "SIM FAIL: no unambiguous PASS: line (or a FAIL: line was present)"
    exit 1
fi
