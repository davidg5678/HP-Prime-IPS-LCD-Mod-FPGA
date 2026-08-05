#!/usr/bin/env bash
# Run EVERY sim target under Verilator. PASS/FAIL per the repo contract.
#
# WHY THIS ONLY NOW EXISTS
#
# Full regression was never practical before. Under Icarus the passthrough
# testbench alone is 4 m 29 s and the slow-regime one is longer, so a sweep of
# all targets ran to roughly half an hour -- long enough that nobody runs it,
# which means in practice the suite was only ever exercised one target at a
# time, and only the target somebody was already thinking about.
#
# Verilator makes the same sweep ~19x cheaper, which changes it from a thing you
# schedule to a thing you type. That is the actual value of the speedup: not
# that any one test finishes sooner, but that "did I break another phase?"
# becomes a question you can afford to ask on every change.
#
# It matters here specifically because src/common/ is shared by seven targets.
# The triple-buffer work touched only passthrough_top.v, but the pipeline
# registers added around test_pattern sit in a module lcd_panel also
# instantiates -- exactly the kind of reach a single-target run cannot see.
#
# `make sim` (Icarus) stays the reference for a single target when something is
# genuinely in doubt. This is the everyday gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TARGETS=()
if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
else
    for d in "$ROOT"/sim/targets/*/; do
        [ -f "$d/files.txt" ] || continue
        TARGETS+=("$(basename "$d")")
    done
fi

pass=0; fail=0; failed=()
start=$SECONDS

for t in "${TARGETS[@]}"; do
    printf '=== %-22s ' "$t"
    if out=$("$ROOT/tools/sim/run_sim_fast.sh" "$t" 2>&1); then
        printf 'PASS\n'
        # Echo the target's own summary line: the numbers in it are the
        # regression detector, not the word PASS.
        echo "$out" | grep -a '^PASS:' | sed 's/^/      /' | cut -c1-160
        pass=$((pass+1))
    else
        printf 'FAIL\n'
        echo "$out" | grep -aE '^(FAIL:|%Error)' | head -5 | sed 's/^/      /'
        fail=$((fail+1)); failed+=("$t")
    fi
done

elapsed=$((SECONDS-start))
echo
if [ "$fail" -eq 0 ]; then
    echo "PASS: all $pass sim targets passed under Verilator in ${elapsed}s"
    exit 0
else
    echo "FAIL: $fail of $((pass+fail)) sim targets failed (${failed[*]}) in ${elapsed}s"
    exit 1
fi
