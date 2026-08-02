# Progress

Update this file at the end of each work session so a future session (human or agent) can
pick up cold. Newest entries at the top.

## 2026-08-02 (later session) — proto-phase-1: hardware self-test PASSES; root cause was reset, not the bridge

**Status: RESOLVED and verified end-to-end. `make selftest-hw` →
`PASS: hardware serial self-test, 256 bytes verified, 0 errors`, 5/5 consecutive runs. `make sim`,
`make sim SIM_TARGET=bringup_selftest`, `make build`, `make flash-sram`, `make check-env` all
pass. The mock/real runtime mux was also verified over the wire.**

### Root cause: the design was held in reset the entire time

`rst` was mapped to **pin 88, which is the GW2AR-18C's `MODE0` configuration strap**, not a plain
GPIO — visible all along in the Gowin pin report (`impl/pnr/project.rpt.txt`, Function column for
`rst`). The board's strapping overrides the `.cst`'s `PULL_MODE=UP`, so `rst` read low, `rst_n`
stayed asserted, and every sequential block except one was frozen. `uart_tx` sat at its reset
value (idle high) and the FPGA never transmitted a single bit.

**Why three sessions of diagnosis missed it:** `heartbeat` is the one register in
`bringup_selftest_top.v` declared `always @(posedge clk)` with *no* reset term. It therefore keeps
counting while the rest of the design is in reset. Every "heartbeat LED confirms the bitstream is
alive" check in the sessions above was true *and* fully compatible with the design being dead.
The previous session's multimeter reading corroborated this and was misread at the time: pin 72
measured **3.4V**, but a pin actively streaming UART data would average ~1.6V (one start bit low,
~50% data ones, stop bit high). 3.4V was an undisturbed idle line — the FPGA saying it wasn't
transmitting.

Fix: an internal power-on reset (`por_cnt`, releases ~1.2ms after configuration). Pin 88 is no
longer in the reset path; `leds[4]` now exposes its raw level for visual confirmation.

**The BL616 investigation in the session below was very likely chasing a ghost.** Pins 69/70 would
have been equally silent for this same reason. Whether the `AppleUSBFTDI` claim is a real
additional obstacle is now untested — worth re-checking before anyone invests in that path again.

### Three further real bugs found once the link came up

1. **`tx_ready` was used before declaration** (line 55 vs 67), creating an implicit net. Gowin only
   *warned* (`WARN (EX3638)` — present in every build log and treated as cosmetic); iverilog
   rejects it outright, which is why this target had never had a top-level testbench. Declaration
   moved above first use.
2. **The LFSR advanced twice per transmitted byte.** `en(tx_ready && mode_mock)` — `tx_ready` is
   high for *two* cycles per byte, not one. The FPGA's stream could therefore never have matched
   `serial_selftest.py`'s reference model even with a perfect link. Now gated on
   `tx_fire = tx_ready && tx_valid`, a clean one-cycle-per-byte pulse (also used for `tx_count`
   and `real_data_stub`).
3. **Free-running TX made framing impossible.** `tx_valid <= tx_ready` streamed back-to-back
   forever with no inter-frame idle, so a receiver had no way to establish framing (a data bit's
   falling edge is indistinguishable from a start bit), and `serial_selftest.py`'s "first byte
   after resync == SEED" raced against bytes already in flight. Replaced with **burst-on-demand**:
   `CMD_RESYNC` reloads the seed and arms exactly `BURST_LEN` (256) bytes; the line is idle
   otherwise.

### Bridge throughput: the two links now run at different baud rates

With everything above fixed, the self-test got to **byte 115 of 256** and then read `0xe7` where it
expected `0xf3` — and `lfsr_next(0xf3) == 0xe7`, i.e. exactly one byte *dropped*, not corrupted.

`SoftwareSerial`'s RX ISR holds interrupts disabled for a whole byte time, which blocks the
hardware USART's `UDRE` interrupt and stalls outgoing TX. At 115200 on both sides the outbound
rate is therefore *strictly lower* than the inbound rate, and a sustained burst overruns the
64-byte buffer regardless of its size. Fixed by decoupling the two links:
- `USB_BAUD  = 115200` (hardware UART, Uno ↔ Mac) — matches `BAUD` in both Python scripts
- `FPGA_BAUD = 38400`  (bit-banged, Uno ↔ FPGA) — matches `BAUD` in `bringup_selftest_top.v`

This is a *bridge* limitation, not an FPGA one. If the BL616 path (or a real USB-serial adapter)
is ever adopted, both sides can go back up.

### New: `sim/targets/bringup_selftest/` — top-level testbench

The gap that let all of the above through: `bringup_uart_loopback` only tests `uart_tx` against
`uart_rx`. Nothing tested `bringup_selftest_top` itself. The new testbench checks the on-the-wire
bit time (recovering baud from the narrowest edge-to-edge interval — the shortest possible UART
pulse is exactly one bit), the LFSR-to-byte cadence 1:1, deterministic framing (byte 0 must be
SEED exactly), and the RX command channel. It caught bugs 2 and 3 directly.

Two testbench-authoring notes worth remembering: `micros()`-style sequential capture must be
armed **before** the command finishes going out (`uart_rx` asserts `rx_valid` mid-stop-bit and the
burst starts ~4 clocks later, while `send_byte` is still driving its own stop bit — hence the
`fork`/`join`), and the watchdog is counted in **clocks**, not a `#delay`, because the required
ceiling in ps overflows Verilog's default 32-bit unsized literal.

### Host tooling fixes

- `serial_selftest.py`'s `find_port()` fell back to `ports[0]`, which on macOS is reliably
  `/dev/cu.Bluetooth-Incoming-Port` — it opens fine and returns nothing, producing a confusing
  0-byte timeout. Now filters on the Arduino VIDs like `arduino_bridge_selftest.py` does.
- Opening the port asserts DTR and **auto-resets the Uno**; the bootloader then holds the line for
  ~1.5s and swallows anything sent during that window. Added a `--settle` wait (default 2.5s).
- `--count > BURST_LEN` now fails with an explicit message instead of a bare timeout.

### Not yet done / open questions

- `leds[4]` (raw pin 88 level) has not been read visually — the MODE0 strap explanation is
  confirmed from the vendor pin report and from the POR fix working, but the pin's actual level
  was never directly measured. Quick confirmation for whoever is next at the bench.
- `CMD_RESYNC` reloads the LFSR seed but does **not** reset `real_data_stub`, so REAL mode resumes
  from wherever the counter was. Harmless (it wraps every 256 bytes, so bursts look identical),
  but making resync reset both would make the reference implementation deterministic in both
  modes — worth doing when Phase 1 copies this pattern.
- The board's second button (pin 87) was never tested as a reset source. If a physical reset is
  wanted, verify pin 87 has no dual-purpose function before wiring it into the reset path.
- **There is no `.sdc`, so no timing analysis is actually running.** The two remaining `gw_sh`
  warnings say so: `WARN (TA1132) 'clk' was determined to be a clock but was not created` and
  `WARN (PR1014) Generic routing resource will be used to clock signal 'clk_d'` (i.e. `clk` is not
  on a global clock buffer). Both are harmless for a 27 MHz design this small — and the
  open-source path independently reported ~248 MHz Fmax — but this should be fixed before Phase 1
  adds BSRAM and a PLL, where unanalysed timing stops being safe.

## 2026-08-02 — proto-phase-1: BL616 UART dead end on macOS, Arduino bridge in progress (unresolved)

**Status: IN PROGRESS, not passing yet. Board connected all session. `make check-env`, `make
build`, `make build-oss`, `make flash-sram` all still work. Hardware UART self-test
(`make selftest-hw`) still fails — currently 0 bytes received through the newest bridge
configuration. Next action on resume: check whether `leds[3]` (the new sticky rx-indicator, see
below) lights up after sending a byte through the Arduino relay sketch — that question was
in-flight when this session paused.**

### Part 1: the BL616 onboard UART is unusable from macOS (dead end, not pursued further)

Ran the documented next step from the 2026-07-30 session: `make flash-sram` then
`make selftest-hw` against `bringup_selftest`. Flash succeeded and the bitstream was confirmed
alive (heartbeat LED), but the self-test timed out with 0 bytes.

Diagnosed extensively: both enumerated serial endpoints of the onboard debugger tested in both
directions, at multiple baud rates, with DTR/RTS explicitly controlled — all silent. Installed
`pyftdi` (`pip install --user --break-system-packages pyftdi`, plus `brew install libusb`) to
bypass the OS tty layer and talk to the FTDI-emulated interfaces directly: one interface returned
0 bytes, the other timed out entirely on a USB control transfer (macOS's built-in
`AppleUSBFTDI` kernel driver claims both interfaces exclusively; getting `pyftdi` to touch the
second one would require `sudo kextunload`, judged too invasive to do without asking first).

Pulled the official Sipeed KiCad schematic (`tang_nano_20k_schematic_v1.3.pdf`, readable directly
via the `Read` tool's PDF support) to settle it definitively: `USB_JTAG.kicad_sch` confirms chip
`U5` is genuinely a `BL616C-S0-Q2I-QFN40` (not FTDI silicon — it emulates an FTDI FT2232H USB
descriptor purely for driver compatibility, which is why `ioreg`/`system_profiler` reported FTDI
VID:PID `0403:6010`). `MAIN.kicad_sch` confirms `PIN69_SYS_TX`/`PIN70_SYS_RX` wire directly to
`BL616_UART_TX`/`BL616_UART_RX` with no jumper — i.e. **the RTL and `.cst` pin assignment were
correct all along; this is a host driver problem, not a design bug.** `boards/tangnano20k/
pinout.md` updated with a caveat pointing here instead of asserting the BL616 UART "just works."

### Part 2: Arduino Uno bridge — attempt 1 (bare 16u2 adapter via grounded RESET) — abandoned mid-diagnosis

Plan (drafted locally, then refined via an Ultraplan cloud session and teleported back — that
mechanism has no git remote/branch integration in this repo currently, the "teleport" just
re-delivers the plan text into the local conversation) called for grounding the Uno's `RESET`
pin to disable the ATmega328p, using the 16u2 chip as a bare USB-CDC-to-UART adapter on D0/D1, at
1,000,000 baud (matching the design), with a 1kΩ/2kΩ resistor divider stepping the Arduino's 5V
`D1` output down to ~3.33V before it reaches the FPGA's 3.3V-only `uart_rx` pin.

Built: `python/tools/arduino_bridge_selftest.py` (loopback self-test, PASS/FAIL contract),
`boards/tangnano20k/arduino_bridge.md` (now rewritten for attempt 2, see below), `Makefile`
`selftest-bridge` target + `PORT=` override on both hardware-test targets. Had to widen
`find_port()`'s VID filter from just `0x2341` to `(0x2341, 0x2a03)` — this specific Uno enumerates
under Arduino SA's `0x2a03`, not the older Arduino LLC `0x2341`.

**Phase A (Arduino-only, FPGA disconnected) passed:** `make selftest-bridge` →
`PASS: arduino bridge loopback, 256 bytes verified, 0 errors` at 1,000,000 baud — confirmed the
16u2 could drive/receive real data at the design's full baud rate at that point in time.

User caught before wiring to the FPGA that pins 69/70 (originally documented) are hard-wired
directly to the BL616 (see Part 1's schematic finding) — driving them externally would contend
with the BL616's own driver. Remapped `bringup_selftest`'s `uart_rx`/`uart_tx` to pins 71/72
instead (`bringup_selftest.cst`, RTL port comments, `pinout.md` table all updated to match).

Rebuild hit a real, now-fixed tooling bug: `gowin_build.sh`'s final `cp` failed with
`Permission denied` — `gw_sh` writes its `.fs` output read-only, and a plain `cp` can't overwrite
a read-only destination left over from a prior build of the same target. Fixed with `cp -f`
(comment left in place explaining why).

**Phase B (real FPGA, pins 71/72) failed: 0 bytes, both directions silent.** Systematic diagnosis
with the user, in order: heartbeat LED confirmed bitstream alive (rules out reflash/reset
problems) → `FORCE_REAL` command sent via the bridge, mode LED (`leds[1]`) didn't change (RX
direction not getting through) → common ground confirmed present → D1→pin71/D0→pin72 orientation
confirmed correct (no TX/RX swap) → multimeter at pin 71 read 0.5V instead of the expected
~3.33V idle-high (pin 72, the FPGA's own driven output, correctly read 3.4V, validating the
measurement technique) → resistor values confirmed correct (1k/2k) → theorized the 16u2 might
only actively drive TX while the host's virtual COM port is open; tested by holding the port open
during a fresh measurement — no change → **isolated further with a forced serial BREAK
toggle (idle-high → held-low → idle-high) while probing `D1` directly, out of circuit with
everything downstream disconnected — the user found literally no voltage response to any of it.**
Root cause of *that* was never determined (most likely theory: the `RESET`→`GND` jumper had come
loose while rewiring for the FPGA connection, letting the 328p resume control of the shared D0/D1
bus and contend with the 16u2 — consistent with Phase A having worked earlier in the exact same
nominal configuration) — **not confirmed, abandoned in favor of a different approach** rather
than root-caused further.

### Part 3: Arduino Uno bridge — attempt 2 (real sketch on the 328p via SoftwareSerial) — in progress

User's call: stop fighting the bare-16u2/grounded-RESET trick, disconnect that jumper, and run a
normal sketch on the 328p instead. Since the Uno's one hardware UART is already committed to the
USB link (via the 16u2, used normally now), the FPGA link moved to a `SoftwareSerial` pair on
spare pins D2 (RX, direct from FPGA pin 72)/D3 (TX, through the same 1k/2k divider, to FPGA pin
71) — RESET is *not* grounded in this approach.

Installed `arduino-cli` (`brew install arduino-cli`) + the AVR core
(`arduino-cli core install arduino:avr`) for headless compile/upload, matching this repo's
headless-tooling ethos. New sketch: `arduino/fpga_uart_bridge/fpga_uart_bridge.ino` — a plain
byte-for-byte relay between `Serial` (USB/Mac) and `fpgaSerial` (`SoftwareSerial(2,3)`, FPGA).
Compiled and uploaded successfully (`avrdude`, 3112 bytes, exit 0) — this also incidentally
confirmed the `RESET` jumper really was disconnected, since bootloader upload needs the normal
auto-reset sequence.

**Baud dropped to 115200 everywhere** (`SoftwareSerial` is bit-banged and can't reliably hit
1,000,000 baud on a 16MHz AVR — this is the documented fallback path from the original plan,
now actually needed): `bringup_selftest_top.v`'s `BAUD` localparam, `serial_selftest.py`'s and
`arduino_bridge_selftest.py`'s `BAUD` constants, and the sketch's `BAUD` constant all changed
together. Rebuilt and reflashed (`make build && make flash-sram`) — hit a transient
`unable to open ftdi device` on the first flash attempt right after the Arduino upload (JTAG
device briefly not enumerated, likely a USB re-enumeration blip from reprogramming the Arduino on
the same host); succeeded immediately on retry with no code changes.

`make selftest-hw PORT=<arduino-port>` against the new sketch-relay path: still 0 bytes. Heartbeat
LED reconfirmed alive. Sent `FORCE_REAL` again; user (reasonably) didn't have `leds[1]`'s
mode-snapshot semantics memorized, so added a new **sticky diagnostic LED** instead of continuing
to rely on it: `leds[3]` (pin 18) in `bringup_selftest_top.v` now latches on permanently the
instant the FPGA receives even one valid UART byte since reset (`rx_ever` register, set by
`rx_valid`, never cleared except by `rst_n`) — unlike `leds[1]`, it needs no timing/interpretation
to read. Rebuilt, reflashed. Sent a test byte through the new sketch relay. **Session paused
before checking whether `leds[3]` lit up — this is the next thing to check on resume.**

### Current wiring (as of session end)

Arduino Uno: `RESET` **not** grounded (running `fpga_uart_bridge.ino` normally). `D3` (softSerial
TX) → 1kΩ/2kΩ divider → FPGA pin 71 (`uart_rx`). `D2` (softSerial RX) ← direct wire ← FPGA pin 72
(`uart_tx`). Common GND confirmed present between boards. FPGA's own USB (JTAG/debugger) also
connected throughout. Both `bringup_selftest` (FPGA) and the sketch (Arduino) are running at
115200 baud. See `boards/tangnano20k/arduino_bridge.md` for the full current wiring
reference — it's been kept in sync with this approach, not the abandoned attempt 1.

### Not yet done / open questions for next session

- ❌ Hardware self-test still not passing. Immediate next step: check `leds[3]` after sending a
  byte via the Arduino relay (`python3 -c` snippet or `make selftest-hw`) — if it lights up, RX
  direction works and the remaining fault is TX (FPGA→Arduino→Mac); if it stays dark, RX is still
  broken and the fault is upstream of the FPGA (sketch, D3/divider, or pin 71 connection) —
  re-verify the D3 node voltage with a multimeter (expect ~3.3V, matching the earlier pin-71
  measurement methodology from attempt 1) as the next diagnostic if so.
- Root cause of attempt 1's D1-driving failure was never confirmed (theory: loose `RESET`
  jumper) — moot for now since attempt 2 doesn't use that trick, but worth remembering if a
  future bare-16u2 approach is ever retried.
- `gowin_build.sh`'s `cp -f` fix is real and should stay; not board/pin-remap-specific.
- Baud is now 115200 across the whole `bringup_selftest` design, not the original 1,000,000 —
  this is a permanent change (SoftwareSerial constraint), not reverted when/if the BL616 path or
  attempt-1-style bridge is ever revisited (those could go back to 1,000,000 if desired).

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
