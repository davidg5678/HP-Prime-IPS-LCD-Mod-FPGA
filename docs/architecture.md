# Architecture

## Background: what's being reverse-engineered

The HP Prime calculator's LCD panel is believed to be driven by a serial-RGB-to-parallel-RGB
TFT controller in the ILI9322 family: the calculator's main SoC drives the controller over a
"serial RGB" interface (a DOTCLK, HSYNC, VSYNC, DE, and an 8-bit data bus carrying R/G/B bytes
time-multiplexed, 3 clocks per pixel — not a single-wire serial link), and the controller
converts that into full parallel RGB to drive the physical panel. That's ~11 signals total,
well within reach of the Tang Nano 20K's GPIO once probe points are found on the board.

## Toolchain decisions

- **`gw_sh` (Gowin's headless Tcl shell) is the primary/signoff build path.** It produces
  vendor-accurate bitstreams, which matters once BSRAM/PLL/SDRAM primitives are in play
  (Phases 1/3/4). Its one real obstacle — silent `dyld` failures — is solved and encoded in
  `tools/build/gowin_build.sh`: both `DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH` must point
  at the IDE's bundled `lib/` dir, and it must be invoked with a `.tcl` file argument, not `-c`.
- **`oss-cad-suite` (yosys + nextpnr-himbaechel + Project Apicula) is a secondary, fast
  lint/build sanity-check path**, not signoff — Apicula's Gowin device coverage is less mature
  than the vendor tool. Useful as a quick second opinion before committing to a full `gw_sh`
  run. Not a plain Homebrew formula; fetched as a prebuilt bundle by
  `tools/setup/install_tools.sh`.
- **`openFPGALoader` over Gowin's `programmer_cli` for flashing** — simpler flags, actively
  maintained, confirmed DirtyJTAG-v2 support for the Tang Nano 20K's onboard BL616 debug MCU.
  `programmer_cli` stays available as a fallback.
- **Icarus Verilog (plain Verilog testbenches) over cocotb, for now.** iverilog gives the
  fastest possible inner loop — sub-second compiles, and a `PASS:`/`FAIL:` `$display` +
  `$fatal(1)` convention is the simplest possible signal for an agent to parse. Verilator runs
  first as an informational lint pass (`--lint-only -Wall`) to catch latch inference / width
  mismatches a passing-but-incomplete testbench would miss. **cocotb is deliberately deferred
  to Phase 2**, where a single Python model can serve as both the testbench oracle and the
  host-side decoder — introducing it earlier would add async-Python debugging surface to the
  most foundational tests for no present benefit.

## Mock-mode convention

Every phase's top-level module instantiates **both** a mock pattern generator and the real
signal path, selected at **runtime** by a `mode` register (default = MOCK at reset/power-on)
via a UART command byte — never `` `ifdef `` build variants. Two reasons: `ifdef` variants mean
two separate bitstreams, doubling every synth+PnR cycle in an agent's loop, and create a real
risk of losing track of which variant is currently flashed — a silent, hard-to-debug failure
mode this project specifically wants to avoid in unattended iteration. The FPGA has ample LUT
headroom to hold both paths in one bitstream, so mode switches happen over serial in
milliseconds with no rebuild or reflash. `src/targets/bringup_selftest/bringup_selftest_top.v`
is the reference implementation; later phases copy this pattern rather than reinventing it.

## Phase roadmap

- **Phase 1 — logic analyzer.** Capture DOTCLK/HSYNC/VSYNC/DE + 8-bit muxed RGB into on-chip
  block SRAM (capture-then-drain, SUMP/OLS-style — sample rate exceeds sustainable UART
  throughput for live streaming). Reuses `uart_tx`/`uart_rx`/the command channel from
  proto-phase-1 verbatim for the drain path and arm/trigger control. **AI-development
  optimization**: an internal synthetic video-timing generator feeds the *same* capture
  pipeline in mock mode, so trigger logic, buffer depth, and bus decoding are fully
  agent-validatable against a known-correct synthetic pattern — only final validation against
  the real calculator needs a human to attach probe wires.

- **Phase 2 — Python decode/render.** Lives in `python/`, already scaffolded. **AI-development
  optimization**: synthetic captures from Phase 1's mock mode become fixture files under
  `captures/fixtures/` with known-correct expected images, enabling pure offline unit tests
  (decoded pixels compared exactly) with zero hardware — the fastest inner loop of all four
  phases. Natural point to introduce cocotb, reusing this same Python decode model as the
  testbench oracle.

- **Phase 3 — physical LCD driver.** Drives the RGB LCD header (pins documented in
  `boards/tangnano20k/pinout.md`). Reuses the pattern-generator building block from Phase 1's
  mock as a synthetic test-image source. **AI-development optimization**: timing-generator
  correctness (sync pulse widths, porches) is fully checkable in simulation against numeric
  spec before any physical panel is needed.

- **Phase 4 — live passthrough.** Composes Phase 1's capture path directly into Phase 3's
  driver path, reusing the same runtime mux/command-channel convention to select between
  {mock→LCD}, {live HP Prime capture→LCD}, {live capture→USB as in Phase 1} — all in one
  bitstream. Main new risk is clock-domain crossing / rate-matching between capture and drive
  timing. **AI-development optimization**: unit-testable in isolation via a randomized
  FIFO fill/drain testbench before ever combining with real video.
