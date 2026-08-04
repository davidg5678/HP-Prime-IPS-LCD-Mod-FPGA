# HP_PRIME_LCD — Claude Code Reference

HP Prime calculator LCD reverse-engineering project on a Sipeed Tang Nano 20K
(Gowin GW2AR-LV18QN88C8/I7). Four phases — see `docs/architecture.md`. Phase 1 (logic analyser)
and the SDRAM controller are done and working on hardware; Phase 2 captures and decodes whole
frames; **Phase 3 (panel driver) is DONE — the physical panel displays all eight test patterns.**
**Phase 4 (passthrough) passes simulation end to end but has never been synthesised or run.** See `PROGRESS.md` for current status before assuming anything below has
actually been run/verified this session.

**The calculator's LCD bus is reverse-engineered and fully specified in
`docs/prime_lcd_protocol.md`** — 320×240, 8-bit serial RGB, 3 DOTCLKs per pixel, component order
R G B, every figure measured from hardware. Panel compatibility for Phases 3/4 is in
`docs/panel_afy320240a0.md`.

## Directory layout

- `src/common/` — reusable RTL modules across all phases.
- `src/targets/<name>/` — one synthesizable build target: `<name>_top.v` (+ any other sources),
  `<name>.cst`, `files.txt` (ordered source list, common modules first), `top_module.txt`.
- `sim/targets/<name>/` — one testbench, same manifest convention.
- `tools/{setup,sim,build}/` — all automation scripts (see Commands below).
- `python/` — host-side tooling (Phase 2+ decode/render, hardware self-test scripts).
- `captures/` — logic-analyzer capture artifacts (gitignored, regenerable).
- `boards/tangnano20k/pinout.md` — full pin reference table.

Adding a new phase's RTL means adding a new `src/targets/<name>/` (and matching
`sim/targets/<name>/`) directory — the build/sim scripts are generic and should not need
editing.

## Commands

| Action | Command |
|---|---|
| Environment self-check | `make check-env` |
| Simulate (default target `bringup_uart_loopback`) | `make sim` or `make sim SIM_TARGET=<name>` |
| Phase 1 capture over USB serial | `make capture-hw` (add `VCD=captures/x.vcd`) |
| Headless synth+PnR+bitstream (Gowin, primary) | `make build` or `make build BUILD_TARGET=<name>` |
| Open-source lint/build sanity check | `make build-oss` |
| Flash to SRAM (volatile, fast iteration) | `make flash-sram` |
| Flash to on-board flash (persistent) | `make flash` |
| Hardware self-test over USB serial | `make selftest-hw` |
| Phase 3 panel timing check + pattern select | `make lcd-hw` (add `PATTERN=0..7`, `BL=0..255`, `LEDS=on\|off`) |

## Toolchain paths

- Gowin IDE: `/Applications/GowinIDE.app`. Headless shell:
  `.../Contents/Resources/Gowin_EDA/IDE/bin/gw_sh`. **Must** be run with
  `DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH` both set to
  `.../Contents/Resources/Gowin_EDA/IDE/lib`, and invoked as `gw_sh <script.tcl>` (not `-c`).
  This is already encoded in `tools/build/gowin_build.sh` — don't invoke `gw_sh` directly
  without it; the failure mode is silent (it just doesn't do anything useful).
- Open-source path (`yosys`, `nextpnr-himbaechel`, `gowin_pack`/apycula): install via
  `tools/setup/install_tools.sh`, which fetches `oss-cad-suite` (these are NOT plain Homebrew
  formulae) into `~/.local/oss-cad-suite`. Not on PATH by default — either
  `export PATH="$HOME/.local/oss-cad-suite/bin:$PATH"` for the current shell, or add it to your
  shell profile permanently (the install script prints this reminder). `icarus-verilog`,
  `verilator`, `openfpgaloader` are plain Homebrew formulae (note: the brew formula name is
  `icarus-verilog`, the binary is `iverilog`).
- Flashing: `openFPGALoader -b tangnano20k <file>.fs` (add `-f` to persist to flash). Fallback
  if openFPGALoader has trouble: Gowin's own
  `.../Contents/Resources/Gowin_EDA/Programmer/bin/programmer_cli`.
- Device string: `GW2AR-18C` / `GW2AR-LV18QN88C8/I7` (the placeholder project had this wrong —
  missing the `R` — already fixed in `HP_PRIME_LCD.gprj`). `HP_PRIME_LCD.gprj` is
  GUI-only/best-effort; the headless build scripts generate their own self-contained `.tcl` and
  don't read it.

## Verification comes first — read `docs/verification.md`

**Before writing RTL for a new phase, read `docs/verification.md`.** The short version, which is
not negotiable in this repo:

- **Every synthesizable target gets its own top-level testbench**, not just submodule tests.
  proto-phase-1 had a passing `uart_tx`↔`uart_rx` loopback test the whole time while the top level
  had three bugs that made it permanently unable to work. Module tests verify the parts you
  thought about; integration tests verify the assumptions between them.
- **Simulate before you synthesize.** `make sim` is seconds, `make build` is minutes, a hardware
  debug session is hours. "It built" says nothing about whether it works.
- **Treat every toolchain warning as an error until you've read it.** Grep the build log for
  `WARN` after every build.
- **`make build` now fails on timing violations, not just on toolchain exit code.** `gw_sh` exits 0
  on a design with violated setup paths and writes a bitstream anyway; an `la_capture` build did
  exactly that (15 violated endpoints, Fmax 96.8 MHz against 108 MHz) and *passed its hardware
  test* at room temperature. `gowin_build.sh` now parses
  `impl/pnr/project_tr_content.html` and fails on any setup/hold violation, on a missing timing
  report, or on an analysis that covered 0 paths. Adding an `.sdc` makes the analysis run; this
  makes the result matter.
- **Mutation-test a testbench before trusting it.** Break the RTL on purpose and confirm the test
  fails. This found dead logic in `capture_engine`'s trigger: the `!match_d` term could be deleted
  with every test still passing, because the comment described edge-triggering the code did not
  implement.
- **Measure, don't assume** — assert on values recovered from the design (e.g. actual bit time on
  the wire), not on the constants you believe you set.
- **Change one variable at a time**, keeping a known-good state to fall back to.

The cost of skipping this, measured on a design with two UARTs and an LFSR: three debugging
sessions and an entire unnecessary Arduino-bridge subsystem, built to route around a bug that was
never in that part of the system.

## Testbench PASS/FAIL contract

Every testbench must print exactly one of:
- `PASS: <summary>` and call `$finish` on success
- `FAIL: <reason>` and call `$fatal(1)` on failure

plus a watchdog `initial #<cycle-ceiling> $fatal(1);` block. `tools/sim/run_sim.sh` greps for
this and sets its exit code accordingly — this is the contract every new testbench (and
`serial_selftest.py`-style hardware scripts) must follow so results are unambiguous to parse.

## Mock-mode convention (stays consistent across Phases 1, 3, 4)

Every phase's `<name>_top.v` instantiates both a mock pattern generator and the real signal
path, muxed at **runtime** by a `mode` register (default = MOCK at reset/power-on), switchable
via a UART command byte over the same command channel established in
`bringup_selftest_top.v` (`0xAA` = resync, `0x4D` = 'M' = force mock, `0x52` = 'R' = force
real). Note the TX side is **burst-on-demand, not free-running**: `0xAA` reloads the seed and
arms exactly `BURST_LEN` (256) bytes, then the line goes idle. Free-running TX leaves a receiver
no way to establish framing. Mode bytes select the source for the *next* burst but don't arm one
— send the mode byte, then `0xAA`, and drain the full burst before the next command. This is a single-bitstream, runtime-switchable pattern — NOT `` `ifdef ``-based build
variants — chosen specifically so an agent can flip between self-test and real-hardware modes
without re-synthesizing or re-flashing. See `src/targets/bringup_selftest/` for the reference
implementation. Full rationale in `docs/architecture.md`.

## Known gotchas

- **Check the Gowin pin report's Function column before mapping any signal to a pin.** Pin 88
  (used as `rst` originally) is the device's `MODE0` configuration strap; the board's strapping
  overrides `PULL_MODE=UP`, so it reads low and held the entire design in reset for three
  sessions. `bringup_selftest` now uses an internal power-on reset. Look for `MODE*`, `DONE`,
  `RECONFIG_N`, `READY`, `JTAGSEL_N` in `impl/pnr/project.rpt.txt`. Second instance of the same
  lesson: **pin 4 (the 27 MHz clock) is `LPLL1_T_in`**, the left PLL's reference input, not one of
  the five `GCLK_PIN`s — so a design that bypasses the PLL reaches the global clock network through
  generic routing (`WARN PR1014`). Fix by instantiating an `rPLL`, not by suppressing the warning
  — `la_capture` does. Measured outcome: the system clock does move onto `PRIMARY` across all four
  quadrants, but `PR1014` persists, now naming the 27 MHz `clk_d` reference hop into the PLL
  rather than the system clock. Expected; see `boards/tangnano20k/pinout.md`.
- **Pin 87 is `MODE1`** (verified 2026-08-02) and pins **13/75/76/86 wire to the BL616** as
  `SPI_SCLK/MISO/MOSI/DIR`. There is no safe external reset pin on this board.
- **The Gowin report's bank voltages are a tool default for banks with no assigned I/O**, not the
  board's supply. It lists pins 25–42 and 79–86 as `LVCMOS18`; the schematic's POWER sheet shows
  every `VCCO` fed by a 3.3 V LDO. Confirmed 2026-08-03: the `lcd_panel` build assigns pins 25–42
  and every one now reports `LVCMOS33`/`3.3`. `docs/` holds the schematic and datasheet PDFs — read
  them with the `Read` tool's `pages` argument, or `pdftotext -layout` for the net lists.
- **The panel datasheet's AC tables are IMAGES.** `pdftotext` returns the section headings and
  nothing else for pages 9–13 of `docs/AFY320240A0-3.5INTH-C2-spec.pdf`, which reads exactly like
  "there is no timing table" rather than like a failed extraction. Use `Read` with `pages`. Two
  figures (`Thw = 4`, `Tvw = 4`) were missing from `docs/panel_afy320240a0.md` for this reason
  alone, and the SYNC-mode diagram settles a structural question the totals could only imply — the
  sync pulse is nested *inside* the back porch.
- **The board pulls the backlight enable UP, so it defaults ON.** Pin 49 reaches the LP3320's `EN`
  through a 100 Ω series resistor, with a 27 kΩ pull-up to +3V3 alongside it. `PULL_MODE=DOWN` does
  not win against that, so **every bitstream that does not actively drive pin 49 leaves the boost
  converter enabled** — including `la_capture`, `frame_capture` and an unconfigured FPGA. Its
  feedback comes from a sense resistor in series with the *panel's* LED string, so with no panel
  mated it drives an open circuit at maximum. `lcd_panel` therefore ships `BL_DUTY_INIT = 0`.
- **The onboard WS2812 latches its colour; an unassigned pin 79 leaves it lit.** Tying it low does
  not clear it (a permanently low line is just an inter-frame gap) — the only fix is to send 24
  zero bits, which `src/common/ws2812_off.v` does. Pin 79 is also `probe[8]`, so capturing targets
  cannot silence it.
- **A status reply of `a5 02 …` in 10 bytes means the board reset**, not that the link broke. SRAM
  configuration is volatile and the onboard flash still holds `la_capture` (version 0x02, 10-byte
  header), so any power blip silently swaps the running design. Dump raw reply bytes before
  theorising about hardware faults.
- **A signal that must not stall is a signal that must not be reset.** `lcd_timing_gen`'s DCLK
  phase generator deliberately has no reset term: holding it parked stretched the first DCLK period
  by the whole reset length (203.7 ns measured in simulation against a 200 ns spec maximum; ~304 µs
  on hardware, where the POR is 32768 cycles). This is the *converse* of the heartbeat lesson
  below, and it carries the same cost in reverse — DCLK toggling is not evidence the design is out
  of reset, so nothing keys liveness off it.
- **`iverilog` and `GowinSynthesis` are each permissive where the other is strict, in both
  directions.** `WARN (EX3638)` (implicit net) is a Gowin warning and an iverilog hard error;
  `ERROR (EX2000)` (a reg driven from two `always` blocks) is a Gowin hard error that iverilog
  simulates without complaint. Passing one toolchain is not evidence the RTL is well formed —
  run `make sim` *and* `make build`. New RTL here uses `` `default_nettype none `` to make the
  first class of bug an error in both.
- **Every target needs a `.sdc` or no timing analysis runs at all.** `tools/build/gowin_build.sh`
  auto-includes `src/targets/<target>/<target>.sdc` when present. Without one, `gw_sh` emits
  `WARN (TA1132) 'clk' was determined to be a clock but was not created` and reports zero timing
  violations — because it checked zero paths. A clean build log is not a timing signoff. With the
  constraint, `bringup_selftest` reports 351 paths, 0 setup/0 hold violations, Fmax 205 MHz. Read
  the numbers out of `impl/pnr/project_tr_content.html` (`project.tr.html` is only a frameset).
- **Give every register a reset term, especially "is it alive?" indicators.** The heartbeat
  counter was the one register declared `always @(posedge clk)` with no reset, so `leds[0]` kept
  blinking while everything else sat in reset — making "the bitstream is alive" check true and
  useless at the same time. A liveness LED that cannot distinguish *configured* from *running* is
  worse than no LED.
- **`gw_sh` warnings are not cosmetic.** `WARN (EX3638) 'x' is already implicitly declared` means a
  signal was used before its declaration, creating an implicit net. Gowin proceeds; iverilog
  refuses. Grep the build log for `WARN` after each build.
- **UART is over the onboard BL616 — no external adapter.** It exposes two interfaces on the same
  VID:PID (`0403:6010`); interface **A** is JTAG (and echoes writes, which looks like a working
  link), interface **B** is the UART on pins 69/70. It also logs its own firmware messages in ASCII
  on interface B during JTAG programming, so drain the port before testing right after a flash.
  See `boards/tangnano20k/pinout.md`.
- No board may be attached — `make sim`, `make build`, `make build-oss` all work without
  hardware; only `make flash*` / `make selftest-hw` need it.
- LED polarity (`leds[5:0]`) is active-low per convention here; verify against actual behavior
  on first hardware bring-up and adjust if needed.
- `impl/`, `build_oss/`, `sim/.build/` are all regenerated build output — gitignored, never
  hand-edit or commit.
- `gw_sh`'s default `impl/` output directory is relative to its CWD, not the `.tcl` script's
  location. `gowin_build.sh` `cd`s to the repo root (not `impl/`) before invoking it, and looks
  for the deterministically-named `impl/pnr/project.fs` (Gowin's default basename when no
  project name is set) rather than globbing `*.fs` — an earlier version of this script globbed
  and silently picked up a stale bitstream left over from a previous build. It also rejects a
  `project.fs` that predates the current invocation, in case `gw_sh` fails silently.
- **Never point `nextpnr-himbaechel --vopt cst=` or `gowin_pack -s` at a `.cst` file under
  `src/targets/`** — both tools rewrite/annotate the constraints file they're given (with
  internal post-place-and-route site names, not pin numbers), clobbering the human-authored
  source of truth the vendor `gw_sh` build also depends on. `oss_cad_build.sh` copies the `.cst`
  into `build_oss/<target>/` first and only ever touches that copy.
- `nextpnr-himbaechel` needs the **full Gowin part number** as `--device` (e.g.
  `GW2AR-LV18QN88C8/I7`, not the short `GW2AR-18C`) — the short form defaults to an invalid
  speed grade (`'ES'`) and fails. It also separately needs `--vopt family=GW2A-18C` for the
  GW2A series (undocumented in `--help`, found by reading its error message).
- apycula's device database has no separate `R`-variant file — `gowin_pack -d` must be given
  `GW2A-18C`, not `GW2AR-18C` (`GW2AR-18C.msgpack.xz` doesn't exist; the R-variant shares the
  base fabric database).
