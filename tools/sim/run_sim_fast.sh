#!/usr/bin/env bash
# Compile + run a self-checking testbench with VERILATOR; PASS/FAIL for agent consumption.
# Usage: tools/sim/run_sim_fast.sh <sim-target-name>   e.g. passthrough
#
# THE FAST PATH, NOT THE AUTHORITY.
#
# `make sim` (Icarus) stays the reference and stays what every note in this repo
# means by "simulate". This target exists because the inner loop got expensive:
# tb_passthrough runs 320 ms of simulated time = ~34.5 M clock cycles, which vvp
# interprets at ~128 k cycles/s. Measured on that testbench:
#
#     iverilog + vvp        4 m 29 s
#     verilator --binary        14 s      <- 19x, identical verdict, 47/47 checks
#
# vvp is an event-driven INTERPRETER and has no optimisation flag to reach for;
# Verilator compiles to C++ instead. The cost scales with SIMULATED TIME, not
# with how much the testbench checks -- one 16.08 ms panel frame is 1.7 M cycles
# regardless of whether anything inspects it -- so this speedup is what makes
# testing the real (slow-source) rate regime affordable at all.
#
# WHY BOTH ARE KEPT, rather than replacing one with the other. CLAUDE.md already
# records that iverilog and GowinSynthesis are each permissive where the other
# is strict, IN BOTH DIRECTIONS: WARN(EX3638) is an iverilog hard error Gowin
# waves through, ERROR(EX2000) is a Gowin hard error iverilog simulates happily.
# Verilator is a third implementation with its own reading of legal Verilog, so
# agreement between them is evidence rather than tautology -- the same argument
# `make build-oss` rests on. Run this constantly; run `make sim` before you
# build.
#
# -Wno-fatal: the sources carry pre-existing lint warnings (rPLL.v's runtime
# delay, SYNCASYNCNET on rst_n) that are understood and informational. The lint
# pass in run_sim.sh is where those are meant to be read; this script's job is
# speed, and a lint warning must not be able to silently stop the fast loop from
# running.
set -uo pipefail
TARGET="${1:?Usage: run_sim_fast.sh <sim-target-name>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$ROOT/sim/targets/$TARGET"
FILES_TXT="$TDIR/files.txt"

[ -f "$FILES_TXT" ] || { echo "SIM FAIL: missing $FILES_TXT"; exit 1; }
TOP="$(tr -d '[:space:]' < "$TDIR/top_module.txt")"

command -v verilator >/dev/null 2>&1 || {
    echo "SIM FAIL: verilator not on PATH."
    echo "  brew install verilator, or use 'make sim' (Icarus) instead."
    exit 1
}

BDIR="$ROOT/sim/.build/fast/$TARGET"
mkdir -p "$BDIR"
SOURCES=$(sed "s|^|$ROOT/|" "$FILES_TXT")

echo "==> Verilating $TARGET (top=$TOP)"
if ! verilator --binary --timing -Wno-fatal \
        --top-module "$TOP" -Mdir "$BDIR/obj_dir" -o "$TOP" \
        $SOURCES > "$BDIR/build.log" 2>&1; then
    echo "SIM FAIL: verilator build error"
    grep -aE "%Error" "$BDIR/build.log" | head -20
    echo "  (full log: $BDIR/build.log)"
    exit 1
fi

echo "==> Running $TARGET"
LOG="$BDIR/run.log"
"$BDIR/obj_dir/$TOP" 2>&1 | tee "$LOG"

# Same contract as run_sim.sh -- exactly one PASS: or FAIL:, parsed the same way,
# so a result from either engine is interchangeable to anything reading it.
if grep -q "^PASS:" "$LOG" && ! grep -q "^FAIL:" "$LOG"; then
    exit 0
else
    echo "SIM FAIL: no unambiguous PASS: line (or a FAIL: line was present)"
    exit 1
fi
