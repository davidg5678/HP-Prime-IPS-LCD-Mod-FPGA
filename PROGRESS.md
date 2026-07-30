# Progress

Update this file at the end of each work session so a future session (human or agent) can
pick up cold. Newest entries at the top.

## 2026-07-30 — proto-phase-1: agentic dev environment bootstrap

**Status: fully working and verified end-to-end, both build paths. Board not connected this
session, so hardware flash + serial self-test are the one remaining manual step.**

Built:
- Repo scaffolding per `docs/architecture.md` (`src/{common,targets}`, `sim/targets`,
  `tools/{setup,sim,build}`, `python/tools`, `captures/`, `docs/`, `boards/tangnano20k/`).
- Fixed `HP_PRIME_LCD.gprj` device string bug (`GW2A-LV18QN88C8/I7` → `GW2AR-LV18QN88C8/I7`).
- `src/common/{lfsr8,uart_tx,uart_rx}.v` — reusable across all phases.
- `sim/targets/bringup_uart_loopback/` — first self-checking testbench.
- `src/targets/bringup_selftest/` — first synthesizable target, reference implementation of
  the mock/real runtime-mux convention.
- `tools/build/gowin_build.sh` — headless `gw_sh` wrapper (Gowin, primary/signoff path).
- `tools/build/oss_cad_build.sh` — yosys + nextpnr-himbaechel + apycula path (secondary).
- `tools/build/flash.sh`, `tools/sim/run_sim.sh`, `tools/setup/{install_tools,check_env}.sh`,
  root `Makefile`.
- `python/tools/serial_selftest.py` — hardware-loop self-test (not yet run against real
  hardware; board not connected this session).
- `CLAUDE.md`, `docs/architecture.md`, `boards/tangnano20k/pinout.md`, this file.
- Git repo initialized, `.gitignore` in place, initial commit made.

Verified this session (all commands actually run, not just planned):
- ✅ `make sim` — `PASS: uart_tx/uart_rx loopback, 34 bytes verified, 0 errors`, exit 0.
- ✅ `make build` (Gowin `gw_sh`, primary path) — `BUILD PASS`, bitstream produced and
  confirmed to be the actual fresh build (not a stale copy — see bug note below).
- ✅ `make build-oss` (yosys/nextpnr-himbaechel/apycula, secondary path) — `OSS BUILD PASS`,
  after fixing three real integration bugs (see below). nextpnr reports the design closes
  timing at 248 MHz max vs. a 12 MHz requirement — huge margin at this design's size.
- ✅ `tools/setup/check_env.sh` — all `PASS:`/`INFO:` as expected, including a live
  `gw_sh` headless launch check.

Bugs found and fixed during verification (all now encoded as comments/gotchas in
`tools/build/*.sh` and `CLAUDE.md` so they aren't rediscovered):
1. **`gowin_build.sh` silently copied a stale bitstream.** `gw_sh`'s default `impl/` output
   dir is CWD-relative; running it from inside `impl/` produced a nested `impl/impl/pnr/`, and
   the script's `ls impl/pnr/*.fs | head -1` glob picked up a leftover bitstream from the
   original placeholder-blinky build instead (confirmed via MD5 — byte-identical to the old
   file, not the new one). Fixed by running `gw_sh` from the repo root and checking a
   deterministic path (`impl/pnr/project.fs`) with an mtime-freshness guard.
2. **`oss_cad_build.sh` fed yosys a broken multi-file command.** `$SOURCES` (one file per line)
   was interpolated into a double-quoted `-p` script string, so yosys parsed each subsequent
   file path as its own invalid command. Fixed by joining with spaces before interpolation.
3. **`nextpnr-himbaechel`/`gowin_pack` clobbered the source `.cst`.** Both tools rewrite the
   constraints file they're given (with post-place-and-route site names, not pin numbers) —
   pointing them at `src/targets/bringup_selftest/bringup_selftest.cst` destroyed the
   human-authored pin constraints the vendor build also depends on. Caught immediately (the
   harness flagged the unexpected file change) and the original restored from what was written
   earlier in the same session. Fixed by copying the `.cst` into `build_oss/<target>/` first and
   only ever pointing the open-source tools at that throwaway copy.
4. Also needed, found via trial and error against the actual binaries: `nextpnr-himbaechel`
   requires the *full* Gowin part number as `--device` (short form defaults to an invalid speed
   grade) plus an undocumented `--vopt family=GW2A-18C`; `gowin_pack -d` needs `GW2A-18C` (no
   `R` — apycula has no separate R-variant database, it shares the base fabric db).

Not yet done:
- ❌ Hardware flash + `serial_selftest.py` — board not connected this session. Manual follow-up:
  connect the Tang Nano 20K, then `make flash-sram && make selftest-hw`.
- `oss-cad-suite` is installed at `~/.local/oss-cad-suite` but not added to the shell profile's
  PATH permanently (only exported ad hoc during verification) — add it yourself if you want
  `make build-oss` to work without manually exporting PATH first.

Next: once the board is connected and hardware self-test passes, start real Phase 1
(logic-analyzer RTL) — see `docs/architecture.md` for the roadmap.
