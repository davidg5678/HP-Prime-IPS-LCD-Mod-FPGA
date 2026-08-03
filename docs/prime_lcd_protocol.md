# HP Prime LCD bus — protocol specification

Reverse-engineered from the calculator's 45-pin display flex, 2026-08-02. **Every figure here was
measured; none is taken from a datasheet or assumed from a family resemblance.** Where a number
comes from the oscilloscope survey rather than the logic analyser, it says so.

Reproduce any of it with:

```bash
python3 python/tools/la_capture.py --real --probe-check      # per-channel activity
python3 python/tools/decode_prime.py --live --runs           # capture -> pixels
```

## At a glance

| | |
|---|---|
| Resolution | **320 × 240** |
| Interface | 8-bit parallel bus, **serial RGB** — 3 DOTCLKs per pixel |
| Component order | **R, G, B** |
| DOTCLK | **13.289 MHz**, 75.25 ns, ~53 % duty |
| Pixel rate | 4.4297 MHz |
| Line | **1361 DOTCLKs** = 102.435 µs = 9.762 kHz |
| Frame | **259 lines** = 26.53 ms = **37.70 Hz** |
| Active data | 8.69 MB/s |
| Logic family | 3.3 V CMOS |

## Signals

Eleven active signals plus grounds, on twelve consecutive flex pins.

| Flex pin | Signal | Direction | Polarity |
|---|---|---|---|
| 7 | DE | SoC → controller | active **high** |
| 8 | VSYNC | SoC → controller | active **low** |
| 9 | HSYNC | SoC → controller | active **low** |
| 10 | DOTCLK | SoC → controller | — |
| 11–18 | D0–D7 | SoC → controller | — |
| 1, 2, 5, 6, 45 | GND | | |

Flex pins 3/4 are 5.5 V, 25/31 are 5 V, and **32–42 carry the TFT gate-driver rails (16.88 V,
−8.3 V, −3.3 V, 15.4 Vpp at 26.3 kHz)**. Full flex survey in `docs/HP Prime LCD Pinout.xlsx`;
probe wiring to the FPGA in `boards/tangnano20k/pinout.md`.

## Horizontal timing

Measured on the logic analyser at 108 MHz (9.259 ns resolution). Both captured lines were
identical to the sample.

```
       |<--------------------- 1361 DOTCLKs, 102.435 us --------------------->|
HSYNC  ‾‾\_/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_/‾
        1
       |<---- 242 ---->|<-------- 960 active -------->|<---- 159 ---->|
DE     ______________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______________________
```

| Interval | DOTCLKs | Time |
|---|---|---|
| HSYNC low pulse | **1** | 74.1 ns |
| HSYNC fall → DE rise (back porch, includes the pulse) | **242** | 18.21 µs |
| DE high (active) | **960** | 72.25 µs |
| DE fall → next HSYNC fall (front porch) | **159** | 11.97 µs |
| **Total line** | **1361** | **102.435 µs** |

242 + 960 + 159 = 1361, which is exactly the measured HSYNC period. The structure closes with no
residual.

**960 active DOTCLKs ÷ 3 = exactly 320.00 pixels.** That is the measurement that establishes three
clocks per pixel; it came out 320.00, not 319.6.

## Vertical timing

The analyser's 303 µs window holds under three lines, far short of a 26.5 ms frame, so the
vertical figures come from the **oscilloscope survey** and are cross-checked against the
analyser's line period.

| | Value | Source |
|---|---|---|
| VSYNC | 37.7 Hz, active low | scope |
| DE burst envelope | 24.7 ms on / 1.96 ms off | scope |
| Active lines | 24.7 ms ÷ 102.435 µs = **241 → 240** | derived |
| Blanking lines | 1.96 ms ÷ 102.435 µs = **19** | derived |
| **Total** | **259 lines** | derived |

Independent confirmation that the whole model is self-consistent:

```
1361 DOTCLKs/line × 259 lines = 352,499 DOTCLKs/frame
352,499 ÷ 13.289 MHz          = 26.526 ms = 37.70 Hz
scope measured VSYNC          = 37.7 Hz          ✓
```

The frame rate predicted from the analyser's horizontal measurements and the derived line count
lands on the frequency the scope measured directly. Two instruments, different methods, same
answer.

## Pixel format

Each pixel is **three consecutive bytes on D7..D0, in the order R, G, B**, one per DOTCLK, gated
by DE.

```
DOTCLK   1     2     3     4     5     6     7     8     9
D[7:0]  R0    G0    B0    R1    G1    B1    R2    G2    B2
        \___pixel 0___/  \___pixel 1___/  \___pixel 2___/
```

The first byte after DE rises is R of pixel 0. 8 bits per component, so **24-bit colour**.

### Evidence for the component order

The triplet phase was fixed first, independently of colour, by the greyscale captures: 960 DOTCLKs
per DE run dividing to exactly 320.00 pixels at sampling offset 0. With the phase pinned, two
single-colour screens each isolate one component:

| Screen displayed | Captured pixel, all 320 px × 3 lines | Establishes |
|---|---|---|
| red | `ff 00 00` | component 0 = **R** |
| green | `00 ff 00` | component 1 = **G** |
| — | — | component 2 = **B**, by elimination over a 3-component pixel |

Both decode to PPMs that round-trip exactly — 320×3, every pixel `(255,0,0)` and `(0,255,0)` —
so the decoder, the triplet grouping and the image writer are all verified against known ground
truth rather than against each other.

## Data timing — when to latch

**Data changes on the DOTCLK falling edge and is stable across the rising edge. Latch on the
rising edge.**

Measured as the distribution of data-change instants relative to each clock edge, over a full
capture:

| Offset from preceding edge | 0 | 1 | 2 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| after **falling** edge | 65 | 53 | 12 | | | | 3 |
| after **rising** edge | 1 | | | 44 | 74 | 13 | 1 |

Changes cluster 0–1 samples (0–9 ns) after the falling edge. The falling edge is ~4.3 samples
after the rising edge, so the valid window at the rising edge is wide.

Confirmed functionally by sweeping the sampling offset against "how many pixels decode with
R ≠ G ≠ B" on a known-greyscale screen:

| Sampling offset (samples after rising edge) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| mixed-component pixels | **0** | **0** | **0** | **0** | 45 | 66 | 63 | 63 |

## Blanking

Outside DE the data bus is **driven to 0x00**, not tri-stated and not left holding the last pixel.
Across 9358 blanking samples only four distinct values appeared, 9355 of them zero. The bus is
actively driven throughout.

## Two traps when decoding this bus

Both were hit during bring-up and both produce output that looks plausible.

**1. Do not latch midway between DOTCLK rising edges.** It is the natural choice and it is wrong
here: at ~53 % duty the midpoint lands essentially on the falling edge, exactly where the data
changes. The resulting decode is subtly broken — solid areas come out perfect and only pixels at
colour boundaries corrupt, which reads as anti-aliasing rather than as a bug.

**2. Reject runt DOTCLK edges if you are oversampling.** Sampling an asynchronous 13.289 MHz clock
at 108 MHz is only 8.1×, and a 2-FF synchroniser will occasionally resolve a metastable edge into
a one-sample runt — 2 in 8064 half-periods measured. One spurious edge gives a line 961 DOTCLKs
instead of 960, and because pixels are triplets, **every boundary after it shifts by one byte**:
a single bad edge corrupts the rest of the line. `decode_prime.py` rejects rising edges arriving
less than 4 samples apart, which is physically impossible for this clock. The proper fix is
synchronous capture — sampling *on* DOTCLK rather than oversampling it.

## Not yet determined

- **Vertical porch breakdown.** The 19 blanking lines have not been split into front porch, VSYNC
  pulse width and back porch, and the VSYNC/HSYNC phase relationship is unmeasured. Requires a
  capture spanning a frame boundary, which needs more depth than the current 2.9 lines.
- **Controller configuration.** Flex pins 27/28/29 are three isolated 3.3 V logic lines whose
  shape and count match an ILI9322-family SPI configuration interface (CS/SCL/SDI). Capturing
  them at power-on would give the controller's actual register settings instead of inferring them
  from the video timing.
- **Whether the timing is fixed.** Everything here was measured with the calculator idle. Whether
  the SoC changes timing for power saving, or on different UI modes, is untested.

## Consequences for later phases

**Phase 2 (render a frame).** A full frame is 352,499 DOTCLKs = 26.53 ms = **2,864,767 samples**
at 108 MHz, against a 32,768-sample buffer. Sampling synchronously on DOTCLK instead would need
352,499 samples — still 10× the buffer. Whole-frame capture requires the board's 64 Mbit SDRAM.

**Phase 4 (live passthrough).** The Prime's timing is illegal for the replacement panel in every
temporal respect — see `docs/panel_afy320240a0.md`. DOTCLK 13.289 MHz against a 5–8 MHz spec,
line 102.4 µs against 55–65 µs, frame 37.70 Hz against ~58–68 Hz. Only the 320×240 resolution
matches. Passthrough must therefore capture, buffer and re-emit on independent panel-legal
timing — it cannot be a wire-through.

Both point at the same missing component: **the SDRAM controller**.
