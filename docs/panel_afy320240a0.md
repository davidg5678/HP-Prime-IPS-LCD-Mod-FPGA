# Orient Display AFY320240A0-3.5INTH-C2 — compatibility analysis

The replacement panel for Phases 3 and 4. Datasheet: `docs/AFY320240A0-3.5INTH-C2-spec.pdf`.

**Headline: no adapter board is needed for the video path.** The panel's 40-pin FPC matches the
Tang Nano 20K's connector on 38 of 40 pins, and the two that differ are harmless in this
configuration. An adapter buys exactly three things, all optional — see *What an adapter would
actually buy* below.

**But the panel cannot be driven with the HP Prime's timing.** That is the real finding here, and
it decides the shape of Phase 4.

## The panel

| | |
|---|---|
| Resolution | **320 × 240** — identical to the HP Prime's display |
| Size / active area | 3.5″, 70.08 × 52.56 mm |
| Driver IC | **ST7272A or compatible** |
| Interface | Parallel RGB 24-bit + 3-wire SPI config |
| VDD | 3.0 / 3.3 / 3.6 V; V_IH = 0.7 × VDD, so 3.3 V logic |
| Backlight | 12 LEDs, 6S2P, **19.2 V at 40 mA** constant current (abs max 50 mA) |
| Touch | ST1633I capacitive, I²C addr 0x70, 5-point, on a **separate 6-pin FFC** |

## Pin-for-pin against the Tang Nano's FPC-40-0.5mm

Board side from the DISPLAY sheet of `Tang_Nano_20K_3923_Schematics-1.pdf`; panel side from
section 8 of its datasheet. Both connectors are 40-pin, 0.5 mm pitch.

| Pin | Panel | Tang Nano | Verdict |
|---|---|---|---|
| 1, 2 | LEDK, LEDA | `VLED-`, `VLED+` | ✅ |
| 3 | CS — *"Ground"* | GND | ✅ exactly what the panel asks for |
| 4 | VDD | +3V3 | ✅ |
| 5–12 | R0–R7 | R0–R2 → GND, R3–R7 → pins 42, 41, 40, 39, 38 | ✅ 5-bit red |
| 13–20 | G0–G7 | G0–G1 → GND, G2–G7 → pins 37, 36, 35, 34, 33, 32 | ✅ 6-bit green |
| 21–28 | B0–B7 | B0–B2 → GND, B3–B7 → pins 31, 30, 29, 28, 27 | ✅ 5-bit blue |
| 29 | GND | GND | ✅ |
| 30 | DOTCLK | FPGA pin 77 | ✅ |
| 31 | DISP | **hard-tied to +3V3** | ⚠️ see power sequence |
| 32 | HSYNC | FPGA pin 25 | ✅ |
| 33 | VSYNC | FPGA pin 26 | ✅ |
| 34 | DE | FPGA pin 48 | ✅ |
| 35 | SCL (SPI3 clock) | **NC** | ⚠️ harmless — see below |
| 36 | SDA (SPI3 data) | **GND** | ⚠️ harmless — see below |
| 37–40 | XR/YD/XL/YU, *NC on this panel* | FPGA pins 15–18 | ✅ driving NC pins is harmless |

So the board wires **RGB565**, not the panel's full 24-bit. That is a property of the PCB — the
low colour bits are tied to ground on the board — and **no adapter can recover them**, because
the FPGA pins simply are not routed to those connector positions.

### Why grounded SDA and floating SCL do not matter

The panel wants pin 3 (CS) tied to ground, and the Tang Nano does exactly that. From the
datasheet's serial-interface notes:

> Command loading operation starts from the falling edge of CS and is completed at the next
> rising edge of CS.

With CS permanently low there is never a rising edge, so **no serial command can ever latch**.
The SPI is disabled by design and the panel runs on its power-on default registers. A grounded
SDA and a floating SCL cannot corrupt anything, and the panel can never drive SDA (that needs a
read transaction, which needs CS to toggle).

The consequence is that we are committed to the default register set, which fixes the porch
values — see the timing recipe below.

## The real problem: the Prime's timing is illegal for this panel

| | HP Prime (measured) | Panel (datasheet) |
|---|---|---|
| DOTCLK | 13.1 MHz | **5 / 6 / 8 MHz** (min/typ/max) |
| Pixel rate | 4.37 MHz *(if 3 clocks/pixel)* | 5–8 MHz |
| Line period | **104.1 µs** | **55 / 60 / 65 µs** |
| Frame rate | **37.7 Hz** | ≈58–68 Hz (Tv 244–289 lines) |
| Resolution | 320 × 240 | 320 × 240 ✅ |

Every temporal figure is out of range. The Prime's DOTCLK is 64 % above the panel's maximum, its
line period is 60 % longer than the panel's maximum, and its frame rate is below the panel's
minimum. Only the resolution matches.

**Phase 4 therefore cannot be a wire-through.** It must capture a frame, buffer it, and re-emit it
on independently generated, panel-legal timing. This is precisely the "clock-domain crossing /
rate-matching between capture and drive timing" that `docs/architecture.md` names as Phase 4's
main risk — now quantified rather than anticipated.

### Timing recipe for the FPGA output

**Implemented in `src/common/lcd_timing_gen.v` and verified against these numbers in
`sim/targets/lcd_timing_gen/`.**

The full Parallel 24-bit RGB Input Timing Table, typical column. **The AC tables are IMAGES in the
PDF** — `pdftotext` returns nothing for them, so these were read visually from pages 10–13. An
earlier version of this section derived the porches from the totals and did not carry the two pulse
widths:

| | Symbol | Min | Typ | Max | Unit |
|---|---|---|---|---|---|
| DCLK frequency | Fclk | 5 | **6** | 8 | MHz |
| Line period | Th | 325 | **371** | 438 | DCLK |
| Active | Thdisp | | **320** | | DCLK |
| Back porch | Thbp | 3 | **43** | 43 | DCLK |
| Front porch | Thfp | 2 | **8** | 75 | DCLK |
| HSYNC pulse | Thw | 2 | **4** | 43 | DCLK |
| Frame period | Tv | 244 | **260** | 289 | HSYNC |
| Active | Tvdisp | | **240** | | HSYNC |
| Back porch | Tvbp | 2 | **12** | 12 | HSYNC |
| Front porch | Tvfp | 2 | **8** | 37 | HSYNC |
| VSYNC pulse | Tvw | 2 | **4** | 12 | HSYNC |

```
horizontal:  Thbp 43  +  Thdisp 320  +  Thfp 8   =  Th 371 DCLK   (typ 371 ✓)
vertical:    Tvbp 12  +  Tvdisp 240  +  Tvfp 8   =  Tv 260 lines  (typ 260 ✓)

at DCLK = 6 MHz:  line = 61.8 us   (spec 55-65 ✓)
                  frame = 16.08 ms = 62.2 Hz   (spec ~58-68 ✓)
```

**The sync pulse is nested INSIDE the back porch, not adjacent to it.** The arithmetic above only
closes under that reading, and the SYNC-mode diagram on p.11 shows it directly: Thbp is drawn from
the HSYNC falling edge to the start of the display period, with Thw inside it. Same for Tvw inside
Tvbp. Getting this backwards puts the image 4 pixels off with no other symptom, which is why
`sim/targets/lcd_timing_gen` asserts the nesting explicitly rather than only checking the totals.

The datasheet is explicit that with default registers these are not free choices:

> It is necessary to keep Tvbp=12 and Thbp=43 in sync mode. DE mode is unnecessary to keep it.

Since we cannot reach the SPI to change `H_BLANKING`/`V_BLANKING`, either supply exactly those
porches in SYNC mode, or use **DE mode**, where DE alone delimits the active region and the porch
registers are irrelevant. `lcd_timing_gen` does **both** — it emits the exact default porches *and*
a correct DE — so the panel is driven legally in SYNC, SYNC-DE or DE mode, whichever it is actually
in. That costs nothing and removes a failure mode from first light.

### DCLK polarity is unknown, and the design is built not to care

Every figure in the datasheet labels the clock "DCLK (Negative Polarity)", but the figures are
low-resolution scans and which edge the panel latches on cannot be read off them with confidence.
Normally you would set DPOL over the SPI — which is exactly what is unreachable here.

Guessing has a catastrophic wrong side: if data changes *at* the sampling edge, every pixel is
corrupt. So `lcd_timing_gen` transitions data at phase 0 of the 18-cycle DCLK period and places
DCLK's two edges at phases 4 and 13:

| | setup | hold |
|---|---|---|
| falling edge (phase 4) | 37.0 ns | 129.6 ns |
| rising edge (phase 13) | 120.4 ns | 46.3 ns |

Every setup and hold minimum in the AC table is 12 ns (Tdsu, Tdhd, Thst, Thhd, Tvst, Tvhd, Tdest,
Tdehd). The worst of the four figures above is 3.1x that, so the design is correct on **either**
polarity, and duty stays exactly 50% against a 40–60% spec. This is only affordable because 6 MHz
is slow — one DCLK is 18 system clocks at 108 MHz, so quarter-period granularity is free.

If pixels smear on hardware anyway, `DCLK_FALL` and `DCLK_RISE` are the two parameters to move.

### Frame buffer: this is what forces the SDRAM

A 320 × 240 frame at the board's RGB565 wiring is 153,600 bytes = **1.23 Mbit**. The GW2AR-18 has
**828 Kbit** of BSRAM, of which `la_capture` already uses 24 of 46 blocks. A full-colour frame
buffer does not fit.

| Option | Size | Fits BSRAM? |
|---|---|---|
| RGB565 | 1.23 Mbit | ❌ |
| 8 bpp (paletted or RGB332) | 614 Kbit | ✅ tight, 74 % of total |
| Onboard SDRAM | 64 Mbit | ✅ trivially |

This is the *same* conclusion the capture-depth analysis reached from the other direction: a full
frame at 108 MHz is 2.86 M samples against a 32768-sample buffer. **An SDRAM controller is the
single blocker shared by full-frame capture (Phase 2) and the frame buffer (Phase 4)** — which
makes it the highest-value next building block, not Phase 3 RTL.

## What an adapter would actually buy

Three things, all optional, none needed to light the panel:

1. **Control of DISP (pin 31).** The board hard-ties it to +3V3. The power-on sequence wants
   `T1 ≥ 10 ms` between the internal GRB reset going high and DISP going high; tied to the rail,
   DISP rises *with* VDD instead. There is no reset pin on the 40-pin connector, so that reset is
   internal and the requirement is very likely violated. Commodity boards tie DISP high routinely
   and it usually works — but if the panel fails to initialise on power-up, this is the first
   thing to fix, and fixing it means cutting the trace or interposing an adapter, then driving
   DISP from an FPGA pin. **Pin 52 is the one spare FPGA pin** and would serve.
2. **Access to SCL/SDA (pins 35, 36).** Only needed to depart from the default registers — for
   example to change the blanking values, colour mapping or polarity. Would also require lifting
   the board's ground connection on pin 36.
3. **The capacitive touch panel.** It is on a *separate* 6-pin FFC (RESET, VDD, GND, INT, SCL,
   SDA — I²C at 0x70) that the 40-pin connector does not carry at all. The board's pins 37–40 are
   wired for *resistive* touch (XR/YD/XL/YU), which this panel does not have. Touch is not in the
   phase roadmap.

### Also worth handling in RTL, free — done

The power-on sequence requires `T2 ≥ 250 ms` from display signal output to backlight on. The FPGA
owns the backlight enable (`LCD_BL`, pin 49), so Phase 3 should hold it off for 250 ms after the
timing generator starts rather than enabling it at reset.

**Implemented** in `lcd_panel_top` as `BL_DELAY_CYCLES = 27_000_000` (250 ms at 108 MHz), plus a
~1 kHz PWM on the same pin that comes up at **25% duty** — because the board's boost driver was
designed for a different panel and starting dim is the cheap direction to be wrong in. The duty is
settable at runtime over UART (`make lcd-hw BL=<0-255>`). `lcd_panel.cst` also sets
`PULL_MODE=DOWN` on pin 49, so an unconfigured FPGA cannot light the backlight at all.

The top-level testbench overrides the delay to something a simulation can afford and then
separately asserts that the *shipped* default is still ≥ 250 ms, so the simulation shortcut cannot
leak into hardware.

## Before first power-up — checks

- [ ] **FPC contact orientation.** Both connectors are 40-pin 0.5 mm, but the datasheet's
      mechanical drawing marks a specific contact side. If the board's connector expects contacts
      on the other face, the fix is a flipped FFC extension (a few pounds), not an adapter board.
      This needs eyes on the hardware; it cannot be settled from the schematic.
- [ ] **Backlight current.** The panel wants 19.2 V at 40 mA and its absolute maximum is 50 mA.
      The board's boost driver (U6, sense resistor R31 = 5.6 Ω, output cap rated 50 V) is in the
      right region but was designed for Sipeed's own 4.3″ panel. Measure before running it
      continuously — over-driving shortens LED life, and the datasheet says so explicitly.
- [ ] **FFC tail length** reaches from the board's connector to wherever the panel sits.

## Bottom line

Plug it in. The video path needs no adapter, the resolution is an exact match for the Prime, and
the logic levels agree. Accept RGB565, generate panel-legal timing rather than passing the
Prime's through, keep pin 52 in reserve in case DISP needs driving, and expect the SDRAM
controller — not Phase 3 RTL — to be the next real piece of work.

**Status (2026-08-03):** the SDRAM controller is done and working on hardware, and the Phase 3
driver is written and verified in simulation against every number in the AC table above — but has
**not yet been driven into a physical panel**. `make lcd-hw` checks that the FPGA is emitting
correct timing; it cannot check that anything is displayed, because nothing on this connector comes
back to the FPGA. The three checks in the previous section (FFC orientation, backlight current, FFC
length) are still the ones that need eyes on hardware.
