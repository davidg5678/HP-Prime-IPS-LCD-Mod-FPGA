#!/usr/bin/env bash
# Self-test of the dev environment itself. Run first when troubleshooting.
set -uo pipefail
FAIL=0

command -v iverilog >/dev/null 2>&1 && echo "PASS: iverilog on PATH" \
  || { echo "FAIL: iverilog not on PATH (brew install icarus-verilog)"; FAIL=1; }
command -v openFPGALoader >/dev/null 2>&1 && echo "PASS: openFPGALoader on PATH" \
  || { echo "FAIL: openFPGALoader not on PATH (brew install openfpgaloader)"; FAIL=1; }

GW_SH="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh"
GW_LIB="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/lib"
TMPTCL="$(mktemp /tmp/gwsh_check.XXXXXX.tcl)"
echo 'puts GW_SH_OK; exit' > "$TMPTCL"
if [ -x "$GW_SH" ] && DYLD_LIBRARY_PATH="$GW_LIB" DYLD_FRAMEWORK_PATH="$GW_LIB" "$GW_SH" "$TMPTCL" 2>&1 | grep -q GW_SH_OK; then
  echo "PASS: gw_sh launches headlessly"
else
  echo "FAIL: gw_sh did not launch correctly"; FAIL=1
fi
rm -f "$TMPTCL"

if command -v yosys >/dev/null 2>&1 && command -v nextpnr-himbaechel >/dev/null 2>&1; then
  echo "PASS: open-source toolchain (yosys + nextpnr-himbaechel) on PATH"
else
  echo "INFO: open-source toolchain not on PATH yet (optional secondary path; see tools/setup/install_tools.sh)"
fi

if ioreg -p IOUSB -l 2>/dev/null | grep -qiE "bl616|dirtyjtag|sipeed"; then
  echo "PASS: Tang Nano 20K detected on USB"
else
  echo "INFO: no board detected right now (fine for sim-only work)"
fi
exit $FAIL
