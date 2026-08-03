# Progress

Update this file at the end of each work session so a future session (human or agent) can
pick up cold. Newest entries at the top.

## 2026-08-02 (part 8) — component order resolved: R, G, B (confirmed twice). Protocol spec complete.

**Status: the HP Prime's LCD protocol is fully specified.** A red screen captured as
**320 px of `ff 00 00` on every line** — the first byte of each triplet is RED, so the component
order is **R, G, B**.

That is unambiguous because the triplet phase had already been pinned independently, from
greyscale captures: 960 DOTCLKs per DE run dividing to exactly 320.00 pixels at sampling offset 0.
With the phase fixed, the first byte after DE rises is the first component, and a saturated red
screen puts 0xff there.

**Confirmed a second time with a green screen: `00 ff 00` on all 320 px of all three lines.**
Two independent single-colour captures, each isolating a different component:

| Screen | Captured pixel | Implies |
|---|---|---|
| red | `ff 00 00` | component 0 = **R** |
| green | `00 ff 00` | component 1 = **G** |
| — | — | component 2 = **B**, by elimination over a 3-component pixel |

A blue capture would be redundant. Both PPM outputs round-trip: 320x3, 960 px, every pixel exactly
(255,0,0) and (0,255,0) respectively — so the decoder, the triplet grouping and the PPM writer are
all confirmed end to end against known ground truth.

Incidentally the green capture rejected **zero** runt DOTCLK edges where every previous capture
rejected exactly one. That is consistent with the diagnosis — metastability is probabilistic, not
a fixed defect — and is a small independent check that the runt filter is not simply discarding a
real edge every time.

### Complete measured protocol

    320 x 240, serial RGB, 3 DOTCLKs per pixel, component order R G B
    DOTCLK   13.289 MHz, 75.25 ns, ~53% duty; data changes on the FALLING edge,
             latch on the RISING edge
    line     102.435 us (9.762 kHz) = 1361 DOTCLKs: 960 active + 401 blanking
    HSYNC    active low, ~1 DOTCLK wide
    DE       active high, 72.25 us
    VSYNC    active low, 37.7 Hz
    blanking data bus driven to 0x00

### The tool called a correct capture a failure

`decode_prime.py` reported `FAIL: no line decoded cleanly` on the red screen — 320 errors per
line — while printing the perfectly decoded `ff 00 00`. The pass criterion required
`R == G == B` on every pixel.

That was over-fitting to the sample data. Every capture up to that point happened to be of a
greyscale screen, so "greyscale" got quietly promoted from *a property of what I had measured* to
*the definition of correct*. The first genuinely coloured capture — exactly the one the check
existed to enable — was then rejected by it.

Fixed: correctness is now `960 DOTCLKs -> 320 pixels` and nothing else. The mixed-component count
is still reported, because on **known-greyscale** content a nonzero value does indicate a wrong
sampling point or triplet phase, but it can never be a pass criterion. Both captures now pass and
the output labels each line `[greyscale]` or `[N coloured px]`.

Worth remembering as a class of bug: an assertion derived from observed data rather than from the
specification will reject the first input that differs from the sample — and it does so most
confidently at exactly the moment the new input is the interesting one.

### Fixtures

`captures/` is gitignored (regenerable), but `prime_red.json` (uniform red) and
`prime_live.json` (greyscale home screen) are a useful pair to keep locally: one exercises the
coloured path, one the greyscale path, and they caught this bug between them.

### Open

- Capture depth is still 2.9 lines. The protocol is now fully known, so the remaining blocker for
  Phase 2 (render a frame) is purely the **SDRAM controller** — the same piece Phase 4's frame
  buffer needs. Nothing else about the Prime's side is unknown.
- The one runt DOTCLK edge per capture is worked around host-side; synchronous capture would
  remove it at the source and is the same RTL change that enables full-frame capture.

## 2026-08-02 (part 7) — FIRST REAL CAPTURE: the Prime's LCD bus is decoded

**Status: probes connected, all 12 channels live, and the interface is fully characterised from
real silicon. `python3 python/tools/decode_prime.py --live` → `PASS: decoded 3/3 line(s) to 320
pixels with consistent components, 0 errors`.** Bitstream is now in onboard flash, so the board
self-configures on power-up.

### Measured interface specification

Every figure below is from a capture, not a datasheet or an inference:

| Property | Measured |
|---|---|
| DOTCLK | **13.289 MHz**, period 75.25 ns, ~53 % duty |
| Clocks per pixel | **3** — 960 DOTCLKs per DE run ÷ 320 = **exactly 320.00 pixels** |
| Line period | **102.435 µs** (9.762 kHz), **1361 DOTCLKs**: 960 active + 401 blanking |
| HSYNC | active low, **8 samples = 74 ns ≈ 1 DOTCLK** wide |
| DE | active high, **72.25 µs** |
| VSYNC | active low, 37.7 Hz — static within a 303 µs window, as predicted |
| Data timing | changes 0–1 samples after the DOTCLK **falling** edge; **latch on the rising edge** |
| Blanking | data bus driven to **0x00** (only 4 distinct values outside DE across 9358 samples) |
| Content | greyscale in this capture: **R = G = B for every one of 320 px** on every clean line |

The 3-clocks-per-pixel result confirms the ILI9322-family serial-RGB hypothesis
`docs/architecture.md` has carried since the start. 960/320 came out to 320.00, not 319.6 — the
kind of number that needs no interpretation.

### Two decoding traps, both found by measurement rather than reasoning

1. **Latching midway between DOTCLK rising edges is wrong.** It is the obvious choice and it lands
   almost exactly on the falling edge at 53 % duty — precisely where the data changes. Sweeping
   the sampling offset 0–7 samples against "how many pixels come out with R≠G≠B" gave 0 mixed
   pixels at offsets 0–3 and tens at 4+. The failure mode is nasty: solid areas decode perfectly
   and only pixels at colour boundaries corrupt, which reads as anti-aliasing rather than as a
   bug. `SAMPLE_OFFSET = 0` — latch on the rising edge itself.

2. **One spurious DOTCLK edge per capture corrupted a whole line.** Reproducibly, one line per
   capture came out with 961 DOTCLKs instead of 960, and since pixels are triplets, every boundary
   after it shifted by one byte. Cause: oversampling an asynchronous 13.29 MHz clock only 8.1×
   means the 2-FF synchroniser occasionally resolves a metastable edge into a runt — 2 in 8064
   half-periods measured ≤ 1 sample wide. `decode_prime.py` now rejects rising edges arriving less
   than 4 samples apart, which is physically impossible for this clock. 3/3 lines clean afterwards.
   **The real fix is synchronous capture** (sampling ON DOTCLK), which is also what full-frame
   capture needs.

### What a decoded line looks like

Line 0 of a live capture, 320 px in 30 runs — the Prime's home screen:

    52 px  ff ff ff      white margin
   217 px  e1 e1 e1      grey field
     ...   ec/44/1e/ca/48/0e/08/b0 ...   glyph pixels on white

### New tooling

- `python/tools/decode_prime.py` — decodes a capture (saved JSON or live) into pixels, reports
  per-line DOTCLK and pixel counts, writes a dependency-free PPM, PASS/FAIL contract.
- `python/tools/la_capture.py --probe-check` — per-channel transitions, frequency, duty and
  narrowest pulse. This is what confirmed the wiring on first connection.

### Open

- **Component order (R,G,B vs B,G,R) is still undetermined**, because everything captured so far
  is greyscale — R=G=B for every pixel, which cannot distinguish orderings. Resolving it needs a
  screen with known, saturated colour on it. Concrete next step: put something strongly red on the
  Prime's display and re-capture.
- Capture depth is 2.9 lines. Enough for protocol work, not for an image. Full frames need the
  SDRAM controller, which is also what Phase 4's frame buffer needs.
- The one runt edge per capture is worked around host-side, not eliminated. Synchronous capture
  would remove it at the source.
- The WS2812 RGB LED lights because pin 79 is probe channel D4 — expected, cosmetic, does not load
  the signal (its DIN is high-Z CMOS at 5 V). Documented in `la_capture.cst`.

## 2026-08-02 (part 6) — Phase 3/4 panel analysed: no adapter needed, but no passthrough either

**Status: analysis only, no code change. Full write-up in `docs/panel_afy320240a0.md`; phase
roadmap in `docs/architecture.md` updated.** Panel is an Orient Display
**AFY320240A0-3.5INTH-C2** (`docs/AFY320240A0-3.5INTH-C2-spec.pdf`), 3.5″, **320×240 — an exact
resolution match for the HP Prime**, ST7272A driver, parallel RGB 24-bit, 3.3 V logic.

### The adapter question: no adapter needed for video

The panel's 40-pin 0.5 mm FPC matches the Tang Nano's `FPC-40-0.5mm` on **38 of 40 pins**, checked
pin-by-pin against the schematic's DISPLAY sheet. Power, all 24 colour lines, DOTCLK, HSYNC,
VSYNC, DE, DISP and the backlight all line up. The two that differ are both benign:

- **Panel pin 36 (SDA) is tied to GND by the board** and **pin 35 (SCL) is NC.** Harmless, because
  the panel specifies pin 3 (CS) as *"Ground"* and the board does exactly that — and per the
  datasheet, *"command loading … is completed at the next rising edge of CS"*. With CS permanently
  low no serial command can ever latch, so the SPI is disabled by design and the panel runs on
  default registers. Grounded SDA cannot corrupt anything and the panel can never drive it.

The board wires **RGB565**: R0–R2, G0–G1 and B0–B2 are grounded on the PCB. That is a property of
the board, so full 24-bit colour is unreachable by *any* adapter, not just by omitting one.

An adapter would only buy three optional things: control of DISP (see below), access to SCL/SDA to
change default registers, and the capacitive touch panel — which is on a *separate* 6-pin FFC
(I²C, ST1633I at 0x70) that the 40-pin connector does not carry at all. The board's pins 37–40 are
wired for *resistive* touch, which this panel does not have.

### The real finding: the Prime's timing is illegal for this panel

| | HP Prime (measured) | Panel (datasheet) |
|---|---|---|
| DOTCLK | 13.1 MHz | 5 / **6** / 8 MHz |
| Pixel rate | 4.37 MHz (if 3 clk/px) | 5–8 MHz |
| Line period | **104.1 µs** | 55 / **60** / 65 µs |
| Frame rate | **37.7 Hz** | ≈58–68 Hz |
| Resolution | 320×240 | 320×240 ✅ |

Every temporal figure is out of range; only the resolution matches. **Phase 4 cannot be a
wire-through** — it must capture a frame, buffer it, and re-emit on independently generated
panel-legal timing. That is exactly the "clock-domain crossing / rate-matching" risk
`architecture.md` always named for Phase 4, now measured instead of anticipated.

Output recipe derived from the timing table (back porches include the sync pulse width — the only
reading under which the parts sum to the quoted totals):

    Thbp 43 + Thdisp 320 + Thfp 8  = Th 371 DCLK   (typ 371 ✓)
    Tvbp 12 + Tvdisp 240 + Tvfp 8  = Tv 260 lines  (typ 260 ✓)
    at 6 MHz: line 61.8 us, frame 16.08 ms = 62.2 Hz

Because the SPI is unreachable, the datasheet's *"necessary to keep Tvbp=12 and Thbp=43 in sync
mode"* is a hard constraint, not a suggestion. DE mode avoids it entirely and is the lower-risk
choice; the board wires all three of HSYNC/VSYNC/DE so SYNC-DE mode is available.

### SDRAM is the next real building block, ahead of Phase 3 RTL

Two independent requirements converge on it:

- Phase 2 needs whole frames: 2.86 M samples at 108 MHz vs a 32768-sample BSRAM buffer.
- Phase 4 needs a frame buffer: 320×240 RGB565 = **1.23 Mbit** vs **828 Kbit** of BSRAM, half of
  which `la_capture` already uses.

The board's 64 Mbit SIP SDRAM answers both. Fallback if it proves expensive: an 8 bpp or paletted
frame buffer is 614 Kbit and does fit BSRAM.

### Open items on the panel

- **DISP (pin 31) is hard-tied to +3V3 by the board.** The power-on sequence wants `T1 ≥ 10 ms`
  between the internal GRB reset and DISP going high; tied to the rail it rises *with* VDD, so the
  requirement is very likely violated. Commodity boards do this routinely and it usually works —
  but if the panel fails to initialise, this is the first suspect, and the fix needs a cut trace
  or an interposer plus an FPGA pin. **Pin 52 is the one spare** and would serve.
- **`T2 ≥ 250 ms` from display signal to backlight on** — the FPGA owns `LCD_BL` (pin 49), so
  Phase 3 should hold the backlight off for 250 ms after the timing generator starts rather than
  enabling it at reset. Free to implement, easy to forget.
- **FPC contact orientation** — both are 40-pin 0.5 mm, but the contact side needs eyes on the
  hardware. If they disagree the fix is a flipped FFC extension, not an adapter board.
- **Backlight current** — panel wants 19.2 V at 40 mA, absolute max 50 mA. The board's boost
  driver (U6, R31 = 5.6 Ω sense) is in the right region but was designed for Sipeed's own 4.3″
  panel. Measure before running continuously; the datasheet is explicit that over-driving
  shortens LED life.

## 2026-08-02 (part 5) — Prime flex identified from scope data; probe pins re-mapped around the LCD connector

**Status: `la_capture` re-pinned, rebuilt, reflashed and re-verified on hardware
(`make capture-hw` → PASS, and the VSYNC-edge/wrap case → PASS). The twelve probe channels now
use ZERO of the RGB LCD connector's pins, so Phase 3/4 can still drive a panel. No RTL, testbench
or host-tool change — only `la_capture.cst`, a new `options.tcl`, and docs.**

### The scope survey identifies the interface

`docs/HP Prime LCD Pinout.xlsx` (45-pin flex). The arithmetic closes, which is what makes the
identification trustworthy rather than a guess:

| Flex pin | Measured | Signal |
|---|---|---|
| 7 | 9.8 kHz bursts, 24.7 ms on / 1.96 ms off | DE |
| 8 | 37.7 Hz | VSYNC |
| 9 | 9.61 kHz | HSYNC |
| 10 | 13.1 MHz | DOTCLK |
| 11–18 | logic | D0–D7 |

- Frame 26.53 ms, line 104.1 µs → **254.9 lines/frame**.
- Pin 7's *envelope* is the vertical structure: 24.7 ms = 237 active lines, 1.96 ms = 18.8
  blanking lines, total 256.2 — agrees with 254.9 within scope precision. Only DE has that shape.
- ~240 active of 255 total is a **320×240 panel**, which is the Prime's display.
- 1363 DOTCLKs per line. At 3 clocks/pixel that is 960 active + 403 blanking; at 4 clocks/pixel
  1280 + 83. Both plausible — deliberately not guessed, since resolving it is what the capture is
  for.

Twelve consecutive flex pins (7–18) for twelve channels, which is a clean fit to the existing
front end.

### The probe pin map was incompatible with Phase 3/4 — caught before anything was soldered

The original `la_capture` pin map predated the schematic analysis and put **nine of twelve probes
on RGB LCD connector pins** (77, 25, 26, 48, 27–31). It would have worked perfectly for Phase 1
and made Phase 3 impossible. The user caught it by asking whether re-mapping would cost the LCD
connector — the answer was that the *existing* map already had.

The DISPLAY sheet shows the connector permanently reserves twenty pins (25–42, 48, 77) plus 49
and 15–18. After also removing the BL616 pins and the LEDs, the 2×20 headers have exactly
**thirteen** pins left for twelve probes.

### Five of those thirteen are dedicated SSPI configuration pins

`gw_sh` refused them outright:

```
ERROR (PR2017) 'probe[9]' cannot be placed according to constraint,
               for the location is a dedicated pin (SSPI)
```

Without `set_option -use_sspi_as_gpio 1` only **eight** usable pins remain — not enough. So
Phase 1's twelve channels and Phase 4's LCD output can only coexist by reclaiming the SSPI pins.
Added `src/targets/la_capture/options.tcl` and a generic hook in `gowin_build.sh` that sources
`src/targets/<target>/options.tcl` when present; deliberately per-target rather than global,
since repurposing configuration pins is not something to switch on for every build. Safe here:
configuration is over JTAG and user flash is on MSPI (59–62), neither of which this touches.

### Final map (full table with caveats in `boards/tangnano20k/pinout.md`)

    flex   7   8   9  10  11  12  13  14  15  16  17  18
           DE  VS  HS  CK  D0  D1  D2  D3  D4  D5  D6  D7
    FPGA   51  53  71  80  72  73  74  85  79  56  54  55

Confirmed from the placed design: all twelve at the constrained pins, all Vccio 3.3, DOTCLK on
`GCLKT_0`, and **none of the 21 LCD-connector pins claimed**.

Three choices worth not re-litigating: DOTCLK on 80 because it is `GCLKT_0` (synchronous capture,
the only way a full frame fits in memory, needs a real global clock buffer); VSYNC on 53 because
it is the one pin with a 2.2 kΩ pull-up and a corrupted 37.7 Hz frame sync is obvious where a
corrupted data bit is silent; pin 51 over the spare 52 because 52 carries the second DDC pull-up.

### Also corrected

`pinout.md`'s Phase 3 table was carrying numbers from a Sipeed 480×272 example with a "re-verify
before relying on this" caveat. Now verified against the schematic and extended: the connector is
wired **RGB565** (R2..R0, G1..G0 and B2..B0 are tied to GND at the connector), and `LCD_INT0..3`
share pins 15–18 with four of the six LEDs.

### Open / next

- ⚠️ **Blocker for real probing: the Prime's logic level on flex pins 7–18 is unmeasured.** The
  survey records amplitudes for pins 27–29 and the 32–42 group but only frequencies for 7–18.
  These inputs are 3.3 V LVCMOS (V_IH ≈ 2.0 V); 1.8 V will not register. Measure flex pin 10
  (DOTCLK, continuously toggling) before connecting.
- ☠️ Flex pins 32–42 carry 16.88 V, −8.3 V, −3.3 V and 15.4 Vpp at 26.3 kHz — the TFT gate-driver
  region. Also lethal: flex 3/4 (5.5 V), 25 and 31 (5 V).
- Capture depth against real timing: 32768 samples at 108 MHz is 303 µs = **2.9 lines**. Enough to
  settle clocks-per-pixel and porch structure; a full frame is 2.86 M samples. Even synchronous
  capture on DOTCLK is 347,480 samples per frame, 10× the buffer — full-frame capture for Phase 2
  means the board's 64 Mbit SDRAM.
- Flex pins 27/28/29 (three isolated 3.3 V logic lines) look like the controller's SPI config
  interface. Capturing them at power-on would give the ILI9322's actual register settings rather
  than inferring them, which would de-risk Phase 3.
- Physical connection will be a **soldered pigtail to the flex** — hence getting the pin map right
  before wiring rather than after.

## 2026-08-02 (part 4) — PHASE 1: logic analyser capturing, triggering and draining on hardware

**Status: Phase 1 RTL complete and verified on the board. `make capture-hw` →
`PASS: la_capture mock capture, 24577 samples verified (DOTCLK period, HSYNC period, DE width,
RGB pattern), 0 errors`. All three simulations, both build paths, both bitstreams, and
proto-phase-1's own hardware self-test still pass. New target `la_capture`: 12 channels at
108 MHz into 32768 samples of BSRAM, mask/value trigger with selectable EDGE or LEVEL semantics,
pre-trigger history, and a windowed drain over the same 1 Mbaud BL616 link.**

Also merged proto-phase-1 to `main` (`96c1d35`) at the start of this session and re-verified it on
hardware: `make selftest-hw` 5/5, and a throwaway check confirmed `187cc10`'s CMD_RESYNC fix on
real silicon for the first time (mid-burst resync at 108 bytes in restarts the REAL counter at
0x00 — previously only simulated).

### What was built

| File | Role |
|---|---|
| `src/common/pll_27_108.v` | `rPLL` wrapper, 27 → 108 MHz |
| `sim/models/rPLL.v` | behavioural model of the Gowin primitive, sim-only, measures its input rather than parsing `FCLKIN` |
| `src/common/sync2.v` | N-bit 2-FF synchroniser |
| `src/common/video_timing_gen.v` | synthetic serial-RGB source (MOCK), R=x G=y B=x^y |
| `src/common/capture_engine.v` | circular BSRAM capture, trigger, pre/post-trigger, read port |
| `src/targets/la_capture/` | top level, `.cst`, `.sdc` |
| `sim/targets/la_capture/` | top-level testbench, 6 checks |
| `python/tools/la_capture.py` | host driver: arm, trigger, chunked drain, pattern verify, VCD out |

**108 MHz was chosen for two reasons that both had to hold:** `27 × 4` exactly, and
`108 / 1 = DIV 108` exactly for 1 Mbaud. That keeps the entire design in one clock domain — the
probe pins are the only CDC — and preserves the zero-division-error property that made 1 Mbaud
work at 27 MHz. Measured on the wire in simulation: 999,920 baud.

### Four bugs the process caught that the tests as first written did not

1. **Dead trigger logic, found by mutation testing.** Deleting the `!match_d` term from the
   trigger made *no test fail*. With `match_d` cleared at arm, "edge-sensitive" and
   "level-sensitive" are provably identical — the comment described behaviour the code did not
   have. Fixed by making the distinction real and selectable (`'E'`/`'L'`): LEVEL seeds `match_d`
   to 0, EDGE seeds it with the arm-time match so an already-true condition does not fire. This
   matters for the actual job — "capture the next VSYNC falling edge" returns the wrong frame if
   VSYNC happens to be low when the host arms. **Mutation-test a testbench before trusting it.**

2. **`BUILD PASS` on a design that violated timing.** After adding the windowed read, the clamp
   arithmetic became the critical path: Fmax 96.8 MHz against a 108 MHz constraint, 15 violated
   setup endpoints — and `gw_sh` exited 0, wrote a bitstream, and the hardware test *passed* at
   room temperature. Fixed twice over: the clamp is now pipelined across three cycles (nothing
   needs it for ~870 clocks), and `tools/build/gowin_build.sh` now parses
   `impl/pnr/project_tr_content.html` and fails the build on any setup/hold violation, a missing
   timing report, or an analysis covering 0 paths. Adding an `.sdc` (part 3) made the analysis
   *run*; this makes the result *matter*.

3. **No flow control on the drain.** Streaming the full 64 KB buffer at 1 Mbaud loses bytes: four
   consecutive full drains came up 263–1904 bytes short, non-deterministically, because nothing
   stops the FPGA transmitting while the host's driver buffer is full. Reading faster only narrows
   the window. Fixed with a windowed read command (`'G'` + start + count) so the host bounds what
   is in flight; it now fetches in 4096-sample chunks. Header gained a `reply_count` field
   (version 2, 10 bytes) so a clamped request cannot silently desync the stream.

4. **A truncated DE run, found only on hardware.** A capture starts at an arbitrary point in the
   frame, so the first DE run is partial by construction. The host checker flagged
   `DE run of 25 DOTCLKs, expected 96`. The testbench had the same latent flaw and passed by luck.
   Both now only check runs whose rising edge is inside the capture.

### Toolchain divergence, in three different directions in one session

`CLAUDE.md` already recorded that `WARN (EX3638)` (implicit net) is a Gowin *warning* and an
iverilog *hard error*. This session found the other two directions:

- `ERROR (EX2000)` — a reg driven from two `always` blocks — is a Gowin **hard error** that
  iverilog simulates without complaint.
- `ERROR: Multiple edge sensitive events found` — collapsing an async reset and a sync restart
  into `if (!rst_n || restart)` — is a **yosys** hard error that both Gowin and iverilog accepted.
  The first branch of an `always @(posedge clk or negedge rst_n)` block must test the asynchronous
  signal alone; OR-ing a synchronous condition in describes hardware that does not exist.

Passing any one toolchain is not evidence the RTL is well formed. `make build-oss` was documented
as an optional second opinion; on this evidence it is closer to mandatory. New RTL uses
`` `default_nettype none ``, which makes the implicit-net class an error in both tools.

### Board findings (from the schematic and datasheet PDFs now in `docs/`)

- **Pin 87 is `MODE1`** — the previous entry proposed it as the reset-button candidate "pending
  verification". Verified: it is the other half of pin 88's strap pair. This board has no safe
  external reset pin.
- **Pins 13, 75, 76, 86 wire to the BL616** as `SPI_SCLK/MISO/MOSI/DIR` — same hazard as pins
  69/70. Pins 71–74 (`HSPI_D0..D3`) reach only the headers despite the naming, and are safe.
- **The Gowin report's bank voltages are a tool default, not the board.** It lists pins 25–42 and
  79–86 as `LVCMOS18`; the POWER sheet shows every `VCCO` fed by a 3.3 V LDO and the datasheet
  legend marks all banks 3.3 V. Trusting the report would have ruled out the best contiguous probe
  run for no reason.
- Probe pins chosen, all 3.3 V, all header-accessible, none loaded by an onboard component: 77
  (DOTCLK, `GCLKT_1`), 25, 26, 48, 27–31, 71–73. Full table in `boards/tangnano20k/pinout.md`.

### `PR1014` — the earlier prediction was wrong

Part 3 predicted the `rPLL` would clear `WARN (PR1014)`. It does not. What it fixes is real: the
Global Clock Signals table now shows the 108 MHz `clk_s` on `PRIMARY` across all four quadrants,
where before the system clock reached logic through generic routing. But the warning persists,
now naming `clk_d` — the 27 MHz reference hop from pin 4 into the adjacent PLL, a net with one
load and no registers in its domain. Corrected in `pinout.md`, `CLAUDE.md` and the RTL comment.

### Numbers

- Gowin signoff: **4357 paths, 0 setup / 0 hold violations, Fmax 160.8 MHz** against 108 MHz.
- Resources: 847/20736 logic (5%), 493 registers (4%), **24/46 BSRAM** (53%, inferred as `SDPB`),
  21/66 I/O, 1/2 rPLL.
- Open-source path independently: `OSS BUILD PASS`, nextpnr estimates 114 MHz for `clk_s`.
- Capture: 32768 samples × 16 bits = 303 µs at 9.26 ns resolution.

### Open

- **The HP Prime's LCD interface voltage is unknown and blocks real probing.** These inputs are
  3.3 V LVCMOS (V_IH ≈ 2.0 V); if the Prime's bus is 1.8 V it will not register and a level
  shifter is needed. Measure before connecting anything. Nothing else in Phase 1 depends on this —
  the whole path is validated in MOCK.
- `oss_cad_build.sh` still passes nextpnr a 12 MHz target frequency rather than the real
  constraint, so its "PASS at 12.00 MHz" line means less than it looks. Gowin is the signoff path,
  but this should be wired to the `.sdc` value.
- Verilator lint noise (~88 warnings, mostly `PROCASSINIT`/`WIDTHTRUNC`/`ZERODLY` from the rPLL
  model) is high enough to hide a real warning. Unchanged from part 3, now worse.
- `leds[4]` on `bringup_selftest` (raw pin 88 level) still never read visually. `la_capture` does
  not use pin 88 at all.
- No pre-trigger *depth* control: `post_len` is settable, but the split between pre and post is
  implied by it rather than requested directly. Fine in practice.

## 2026-08-02 (part 3) — proto-phase-1 leftovers closed: timing constraints, deterministic resync

**Status: proto-phase-1 CLOSED. Both testbenches pass (`PASS: uart_tx/uart_rx loopback, 34 bytes`
and `PASS: bringup_selftest top-level, baud + LFSR cadence + command channel + mock/real resync`,
measured baud 1,000,028 on the wire). `make build` now runs real timing analysis: 351 paths,
0 setup / 0 hold violations, Fmax 205.4 MHz against a 27 MHz constraint. Branch
`fix/bringup-reset-and-uart-link` merged to `main`.**

Closes the three items the previous entry left open, except `leds[4]`.

### `bringup_selftest.sdc`: the build was reporting 0 violations because it checked 0 paths

`tools/build/gowin_build.sh` already auto-included `src/targets/<target>/<target>.sdc` when
present, so this needed no script change — the file simply did not exist. Without it `gw_sh`
emitted `WARN (TA1132) 'clk' was determined to be a clock but was not created` and ran **no**
static timing analysis whatsoever, while still reporting a clean build. This is the third
instance in this repo of the same failure shape (after pin 88/MODE0 and the missing top-level
testbench): **a tool reporting success because it was asked to check nothing.**

With the constraint: 351 paths, 0/0 violations, Fmax 205.4 MHz — 7.6x margin, and independently
corroborated by nextpnr-himbaechel's ~248 MHz estimate on the open-source path. Read the numbers
from `impl/pnr/project_tr_content.html`; `project.tr.html` is only a frameset.

The `.sdc` also carries three `set_false_path` exceptions with their justifications inline:
`uart_rx` (async input, already 2-FF synchronised inside `uart_rx.v`), `rst` (pin 88, a
diagnostic level wired straight to `leds[4]`, deliberately not in the reset path), and `leds[*]`
(human-visible, skew irrelevant).

### `WARN (PR1014)` is now explained rather than tolerated

`Generic routing resource will be used to clock signal 'clk_d'`. Pin 4's Function column in
`impl/pnr/project.rpt.txt` reads **`LPLL1_T_in`** — it is the left PLL's dedicated reference
input, not one of the five `GCLK_PIN`s. A design that bypasses the PLL therefore reaches the
PRIMARY global network through generic routing. Harmless at this size; the correct fix is to feed
pin 4 into an `rPLL`, which **Phase 1 needs anyway** for its oversampling clock — a PLL output
reaches a global buffer natively. Recorded in `pinout.md` and `CLAUDE.md` as a second instance of
the pin-88 "read the Function column before mapping a signal" lesson.

### `CMD_RESYNC` now restarts every data source

It previously reloaded the LFSR seed only, so REAL mode resumed from wherever `real_data_stub`
happened to be. Harmless in isolation — a full `BURST_LEN=256` burst wraps an 8-bit counter
exactly back to 0, so complete bursts looked identical — but a *partial* burst left the design in
a state no host command could recover. Phase 1 copies this module, and there the REAL source is a
capture buffer's read pointer, where "restart the source" has to mean all sources with no
exceptions to remember. Testbench check 5 covers REAL-mode framing and mid-burst resync, and was
confirmed **discriminating** by reverting the RTL fix and watching it fail with
`real_data_stub=0x41` — a test that has never been seen to fail is not yet known to test anything.

### Removed

`src/main.v` — a leftover Gowin GUI placeholder blinky, listed in no `files.txt` and built by
nothing. `HP_PRIME_LCD.gprj`'s FileList was dangling at it and now points at the real target
sources.

### Open

- `leds[4]` (raw pin 88 / MODE0 level) still not read visually. The strap explanation is confirmed
  from the vendor pin report and from the POR fix working, but the pin's level was never directly
  measured.
- Pin 87 (second button) never checked for a dual-purpose function; relevant only if a physical
  reset source is ever wanted.
- Verilator's informational lint pass emits ~35 warnings, all benign categories (`PROCASSINIT`
  from reset-value initialisers, `WIDTHTRUNC` on localparam division, unused testbench signals).
  Not blocking — `run_sim.sh` treats the pass as informational — but the noise floor is high
  enough to hide a real `LATCH` or width warning once Phase 1 lands. Worth cleaning before then.

## 2026-08-02 (later session, part 2) — Arduino removed; BL616 UART works at 1 Mbaud

**Status: proto-phase-1 COMPLETE. `make selftest-hw` → `PASS: hardware serial self-test, 256 bytes
verified, 0 errors` at 1,000,000 baud over the board's own USB connection, no external hardware.
5/5 consecutive runs, mock/real mux verified over the same link. The Arduino bridge has been
deleted from the repo.**

### The BL616 UART was never broken

Confirmed directly: the previous sessions' conclusion that macOS's `AppleUSBFTDI` made this path
unusable was a **ghost**. The FPGA was held in reset, so pins 69/70 were as silent as everything
else, and the silence was attributed to the host driver. An entire subsystem — Uno, resistor
divider, `SoftwareSerial`, two sketch rewrites, `arduino-cli` toolchain, a second self-test script,
~500 lines of docs — was built to route around a bug that was never on that side of the wire.

`uart_rx`→pin 70, `uart_tx`→pin 69 (checked the pin report's Function column first: both plain
GPIO, empty Function, unlike pin 88's `MODE0`). Worked on the first try.

### Baud raised to 1,000,000

`27 MHz / 1 MBaud = DIV 27` exactly — zero division error, vs. +0.16% at 115200. Simulation
measured 1000028 baud on the wire before anything was flashed. 26x the Arduino bridge's 38400,
which was purely a `SoftwareSerial` limitation. Matters for Phase 1, whose capture-buffer drain is
throughput-bound.

Done as two separately-verified steps — pins first at the known-good 38400, then baud — so each
change had exactly one suspect.

### BL616 interface selection (two real gotchas)

Both interfaces enumerate with identical VID:PID `0403:6010`, serial and location. The only
discriminator is the interface index appended to the macOS device name, so `serial_selftest.py`
sorts by device name and takes the last.

- **Interface A (`...170`) is JTAG and echoes what you write to it** — probing it returns your own
  bytes back, which reads as a working-but-corrupt link.
- **Interface B (`...171`) carries the BL616's own firmware log during JTAG programming**, in ASCII
  (` Write: 0x400000`). A self-test started immediately after `make flash-sram` reads log text and
  reports it as a data mismatch. `serial_selftest.py` now drains until the line is quiet first.

### Removed

`arduino/`, `boards/tangnano20k/arduino_bridge.md`, `python/tools/arduino_bridge_selftest.py`, and
the `selftest-bridge` Makefile target. All recoverable from git history (commit `a432019`) if a
bit-banged bridge is ever needed again — the `SoftwareSerial` throughput analysis in it is sound
and still applies to any AVR-based bridge.

### Added: `docs/verification.md`

A standing document on why testbench work is the primary instrument in FPGA development, not a
quality gate applied afterwards — grounded entirely in this project's measured costs. `CLAUDE.md`
now opens its workflow guidance with it and `docs/architecture.md` points at it first. The central
data point: proto-phase-1 is two UARTs, an LFSR and a mux; it had a *passing* module-level
testbench the entire time; the missing top-level testbench took ~20 minutes to write and found
three real bugs immediately, one of which (`tx_ready` used before declaration) meant the top module
was not legal Verilog and could never have been simulated at all.

### Open

- `leds[4]` (raw pin 88 level) still not read visually.
- Still no `.sdc` — see the previous entry; unchanged and now the main remaining risk for Phase 1.
- `CMD_RESYNC` still doesn't reset `real_data_stub` (harmless; wraps every 256 bytes).

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
