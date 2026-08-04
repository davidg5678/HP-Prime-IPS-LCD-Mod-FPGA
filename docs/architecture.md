# Architecture

> **See `docs/verification.md` first.** Every phase below is described in terms of what it builds;
> that document covers how you find out whether it works, and why on an FPGA that has to come
> first rather than last. Each phase's "AI-development optimization" note below exists precisely
> to keep the verification loop in simulation, where it is fast and fully observable.

> **The bus is now fully characterised — see `docs/prime_lcd_protocol.md`.** Everything below
> about "what is believed" was written before Phase 1 measured it. The hypothesis held: it is a
> serial-RGB interface at 3 DOTCLKs per pixel.

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

**Phase 4 changes the default, and only the default** — see its roadmap entry below. It adds a third
setting, AUTO, because a standalone box cannot wait for a host command to start doing its job.

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

- **Phase 3 — physical LCD driver. DONE, on hardware.** Drives the onboard RGB LCD FPC connector (pins documented in
  `boards/tangnano20k/pinout.md`). Panel is an Orient Display AFY320240A0-3.5INTH-C2, 320x240 — an
  exact resolution match for the Prime. Analysis in `docs/panel_afy320240a0.md`: **no adapter board
  is needed**, the connectors match on 38 of 40 pins, and the board wires RGB565 (the low colour
  bits are grounded on the PCB, so 24-bit is unreachable by any adapter).
  `src/targets/lcd_panel/` = `lcd_timing_gen` (Th = 371 DCLK, Tv = 260 lines at 6 MHz) +
  `test_pattern` (eight diagnostic images) + backlight sequencing + a UART control channel.
  **The AI-development optimization paid off exactly as predicted**: timing-generator correctness
  was fully checkable against the datasheet's numeric spec with no panel attached, and it found two
  real bugs that way — a DCLK period that went out of spec at power-on, and a status field that
  reported correctly only outside vertical blanking. On hardware, `make lcd-hw` reports 371×260
  with 320×240 active at 62.2 Hz, cross-checked against host wall-clock at 62.8 fps, and the panel
  displays every test pattern. Getting there cost one cable: the panel's FFC and the board's J2 are
  opposite contact types (A vs B), which no amount of software can correct — a flipped cable lands
  the panel's VDD, GND and 19 V backlight rail on FPGA I/O pads. See `boards/tangnano20k/pinout.md`.

- **Phase 4 — live passthrough. DONE, on hardware.** The HP Prime's screen is reproduced on the
  replacement panel in real time, entirely inside the FPGA. It worked on the first hardware attempt.
  `make pass-hw` → `PASS: passthrough emitting 320x240 in 371x260 at 62.2 Hz (62.2 fps wall-clock);
  source 320x240 at 37.3 fps, LIVE PASSTHROUGH on the panel`. Flashed persistently, so it boots
  straight into the passthrough with the backlight on and needs no host at all.
  `src/targets/passthrough/` composes Phase 1's capture path into Phase 3's driver path,
  with the runtime mux selecting {mock→LCD} or {live HP Prime capture→LCD} in one bitstream.

  **The power-on default is AUTO, not MOCK — the one place this project departs from the mock-mode
  convention, deliberately.** AUTO shows the test pattern until a captured frame has been *swapped*
  to the reader, then switches to the live passthrough by itself and stays there. Forced MOCK/REAL
  still override absolutely. The reason is that this phase's deliverable is a standalone box —
  calculator in, panel out, no computer — and a bitstream that waits for a host command cannot be
  one. AUTO is also strictly more diagnostic than defaulting to REAL: with the calculator not
  driving, REAL shows black, which is indistinguishable from a dead bitstream, an unseated FFC or a
  backlight at zero, while AUTO shows GRID and thereby reports "everything except the calculator is
  working". `python/tools/passthrough.py` (`make pass-hw`) carries control and telemetry only, a few
  bytes per second; **the pixels never touch the host and Phase 2's UART streaming is retired.**
  `src/common/prime_pixel.v` turns the sampled bus into addressed RGB565 pixels; a double-buffered
  frame store in SDRAM does the retiming; buffers exchange at the *panel's* frame boundary so no
  frame tears. Combined SDRAM load is 3.84 MW/s of ~10.8 MW/s, so no burst mode is needed.

  **It is a TRIPLE buffer, and the two-buffer version it shipped with is the most instructive bug in
  the project.** The original claim — that the panel (62.2 Hz) being strictly faster than the
  calculator (37.7 Hz) makes two enough — is subtly wrong. Reader-faster-than-writer guarantees a
  completed capture is *collected* in time; it does not make a buffer *available* at the instant the
  writer needs one. `ev_done` coincides with the next source frame's start, and at that moment one
  buffer holds the just-finished capture awaiting the panel swap while the other is being displayed,
  so the writer skipped that frame: **18.9 fps captured against 37.7 Hz, exactly half.** With three
  buffers the writer always has somewhere to go and never stops. Measured after the fix: **37.4 fps,
  every frame.**

  Two things about how this was found. It was caught **only** by timing the FPGA's own frame counter
  against host wall-clock — its internal view is perfectly self-consistent at 18.9 — which is the
  same two-instruments argument `docs/prime_lcd_protocol.md` uses for the Prime's frame rate, paying
  off a second time. And **simulation could not have found it**: the testbench runs the source
  *faster* than the panel, the inverse regime, where the effect does not arise. The no-tearing
  invariant the testbench *does* assert on every clock held perfectly; it was simply not the
  property that mattered here.

  **This cannot be a wire-through, and that is now measured rather than anticipated.** Every
  temporal figure of the Prime's output is illegal for the panel: DOTCLK 13.1 MHz against a
  5–8 MHz spec, line period 104.1 µs against 55–65 µs, frame rate 37.7 Hz against ~58–68 Hz. Only
  the 320x240 resolution matches. Phase 4 must therefore capture a frame, buffer it, and re-emit
  it on independently generated panel-legal timing. The "clock-domain crossing / rate-matching"
  risk this phase always carried is exactly that. **AI-development optimization**: unit-testable
  in isolation via a randomized FIFO fill/drain testbench before ever combining with real video.

### Why Phase 3 came before Phase 2's streaming was finished

Phase 2 reached 2.0–2.6 fps over the UART after 4.6x RLE compression, and the measurements in
`PROGRESS.md` (2026-08-03 part 3) showed the ceiling was per-request *latency*, not bit rate —
raising the baud rate to 3 Mbaud made throughput worse, not better. Meanwhile the internal path is
108 MHz x 32 bits = **432 MB/s**, roughly 4000x the serial link.

Since static captures already establish that the protocol is understood — `docs/prime_lcd_protocol.md`
is complete and every figure in it is measured — the remaining value is in the passthrough, which
never touches the host at all. So the UART's job shrank to what it is actually good at: control and
telemetry, a few bytes per second.

**One caveat that survives the change of phase.** Phase 2's open "frames after the first are
partial" bug lives in the capture *re-arm* path, not in the UART — host decoder speed, padding,
VSYNC re-trigger and stale `fetch_pending` were each ruled out. Phase 4 re-arms per frame
continuously, so that bug is likely to resurface there. It is deferred, not fixed.

- **The SDRAM controller is the real next building block**, ahead of Phase 3 RTL. Two independent
  requirements converge on it. A full frame of capture is 2.86 M samples at 108 MHz against a
  32768-sample BSRAM buffer (Phase 2 needs whole frames to render images). A 320x240 RGB565 frame
  buffer is 1.23 Mbit against 828 Kbit of BSRAM, of which `la_capture` already uses half (Phase 4
  needs one to retime). The board's 64 Mbit SIP SDRAM answers both; nothing else does. An 8 bpp
  or paletted frame buffer (614 Kbit) would fit BSRAM and is the fallback if SDRAM proves
  expensive.
