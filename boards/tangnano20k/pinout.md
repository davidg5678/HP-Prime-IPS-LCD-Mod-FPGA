# Tang Nano 20K — Pin Reference

Device: Gowin `GW2AR-LV18QN88C8/I7` (device name `GW2AR-18C`). 20736 LUT4, 15552 FF,
828Kbit block SRAM, 64Mbit onboard SDRAM, 64Mbit flash.

Verified by cross-referencing Sipeed's `TangNano-20K-example` repo `.cst` files against
`litex-boards`' Tang Nano 20K platform file.

## Used by `bringup_selftest` (proto-phase-1)

| Signal | Pin | Notes |
|---|---|---|
| `clk` | 4 | 27 MHz onboard oscillator. Function `LPLL1_T_in` — the left PLL's reference input, **not** a `GCLK_PIN`. See below |
| `rst` | 88 | ⚠️ **`MODE0` config strap — do NOT use as a reset.** See below. Diagnostic only (`leds[4]`) |
| `uart_rx` | 70 | onboard BL616 UART (`PIN70_SYS_RX`), host → FPGA |
| `uart_tx` | 69 | onboard BL616 UART (`PIN69_SYS_TX`), FPGA → host |
| `leds[0..5]` | 15, 16, 17, 18, 19, 20 | Onboard LEDs, active-low |

### The onboard BL616 UART works — no external adapter needed

Verified 2026-08-02 at **1,000,000 baud** (`27 MHz / 1 MBaud = DIV 27`, exact), no external
bridge. The BL616 exposes two interfaces over one USB connection, both enumerating with identical
VID:PID `0403:6010`, serial and location:

| Interface | macOS device (example) | Role |
|---|---|---|
| A | `/dev/cu.usbserial-...170` | DirtyJTAG-v2 — used by `openFPGALoader`. **Not** a UART |
| B | `/dev/cu.usbserial-...171` | The UART wired to FPGA pins 69/70 — **this is the one you want** |

The only discriminator is the interface index appended to the device name, so
`serial_selftest.py` sorts by device name and takes the last. Two gotchas:

- **Interface A echoes what you write to it.** Probing it looks like a working-but-corrupt link.
- **The BL616 logs its own firmware messages on interface B during JTAG programming** (e.g.
  ` Write: 0x400000`, in ASCII). A self-test run immediately after `make flash-sram` can read log
  text and report it as a data mismatch. `serial_selftest.py` drains until the line is quiet first.

An earlier session concluded this path was unusable from macOS because `AppleUSBFTDI` claims both
interfaces exclusively, and built an Arduino Uno bridge to work around it. **That conclusion was
wrong** — the FPGA was being held in reset (see below), so every path was silent and the silence
was misattributed to the host driver. The Arduino bridge has been removed.

### ⚠️ Pin 88 is a configuration strap, not a general-purpose input

The Gowin pin report (`impl/pnr/project.rpt.txt`, Function column) lists pin 88's function as
**`MODE0`** — one of the device's configuration-mode straps. The board's strapping overrides the
`.cst`'s `PULL_MODE=UP`, so it reads low. Wiring it to an active-low reset holds the whole design
in reset forever, which cost three sessions of hardware debugging (see `PROGRESS.md` 2026-08-02).

`bringup_selftest` now uses an **internal power-on reset** and keeps pin 88 only as a diagnostic
on `leds[4]`. **Before mapping any signal to a pin, check the Function column of the pin report
for a dual-purpose name** (`MODE*`, `DONE`, `RECONFIG_N`, `READY`, `JTAGSEL_N`, …).

**Pin 87 was the proposed reset-button candidate "pending verification". Verified 2026-08-02: it
is `MODE1`** — the other half of the same configuration strap pair as pin 88's `MODE0`. Do not use
it as a reset either. This board exposes no safe external reset pin; use an internal power-on
reset, as both `bringup_selftest` and `la_capture` do.

### Pin 4 (the 27 MHz clock) is a PLL input, not a global-clock pin

Same lesson, second instance — found by reading the same Function column. `impl/pnr/project.rpt.txt`
lists pin 4's function as **`LPLL1_T_in`**: the dedicated reference input of the *left PLL*. The
report also shows `GCLK_PIN 0/5` used, i.e. none of the five true global-clock pins are in play.

Consequence: a design that ignores the PLL and drives logic straight from pin 4 gets its clock onto
the PRIMARY global network via generic routing, and `gw_sh` says so:

```
WARN (PR1014) Generic routing resource will be used to clock signal 'clk_d' by the
              specified constraint. And then it may lead to the excessive delay or skew
```

This is harmless for `bringup_selftest` (27 MHz, 205 MHz Fmax, 0 violated endpoints) and **should
not be worked around** — the correct fix is to feed pin 4 into an `rPLL`, which is that pin's
designed purpose. A PLL output reaches a global clock buffer natively. Phase 1 needs a PLL anyway
for its oversampling capture clock.

**Measured 2026-08-02, after `la_capture` actually did this:** the fix works but the warning does
not disappear. What changes is its subject. Before, the design's system clock reached logic
through generic routing; now the report's Global Clock Signals table shows the 108 MHz `clk_s` on
`PRIMARY` across all four quadrants (`TR TL BR BL`), and `PR1014` instead names `clk_d` — the
27 MHz reference hop from pin 4 into the adjacent PLL. That net has one load and, per the timing
report, no registers in its domain at all (`No timing paths to get frequency of clk27`). So the
warning is now about something with nothing timing-critical on it, and is expected to persist.

### ⚠️ Pins 13, 75, 76 and 86 wire to the BL616

Same hazard class as pins 69/70. The schematic's `USB_JTAG` sheet lists `PIN13_SPI_SCLK`,
`PIN75_SPI_MISO`, `PIN76_SPI_MOSI` and `PIN86_SPI_DIR` as BL616 connections — driving any of them
externally means contending with the debug MCU. Pins 71–74 (`HSPI_D0..D3`) appear **only** in the
J6/J8 header nets despite the similar naming, and are safe.

### ⚠️ The Gowin report's bank voltages are a tool default, not this board

`impl/pnr/project.rpt.txt` lists pins 25–42 and 79–86 as `LVCMOS18` with `BankVccio 1.8`. That is
what the tool assumes for a bank holding **no assigned I/O** — it is not what the board supplies.
The schematic's POWER sheet shows `VCCO_4` and `VCCO_5` fed by `ME6211C33` (3.3 V LDOs), and the
datasheet's pinout legend marks every bank `V_IO = 3.3V`. Trusting the report here would rule out
the board's most useful contiguous run of probe pins for no reason.

## Used by `la_capture` (Phase 1 logic analyser)

`clk`, `uart_rx`, `uart_tx` and `leds[5:0]` as above. Twelve probe inputs, all 3.3 V, all on the
2×20 headers, none carrying an onboard component beyond the unpopulated 40-pin LCD FPC connector:

| Channel | Signal | Pin | Board net | Notes |
|---|---|---|---|---|
| `probe[0]` | DOTCLK | 77 | `LCD_CK` | `GCLKT_1` — the only global-clock-capable header pin left after the BL616 SPI pins are excluded. Reserved for a future synchronous-capture mode |
| `probe[1]` | HSYNC | 25 | `LCD_HS` | also 100 Ω series to HDMI `CEC` |
| `probe[2]` | VSYNC | 26 | `LCD_VS` | also 2.2 kΩ to HDMI `HPD` |
| `probe[3]` | DE | 48 | `LCD_DE` | |
| `probe[4..8]` | D0..D4 | 27, 28, 29, 30, 31 | `LCD_B7..B3` | FPC connector only |
| `probe[9..11]` | D5..D7 | 71, 72, 73 | `HSPI_D0..D2` | header only, no other connection |

**Physical wiring note.** On the left header, pins 27, 28, **25, 26**, 29, 30, 31 are seven
*consecutive* positions in that order — 25 and 26 sit between 28 and 29, which is not what the
numbering suggests. Pins 71/72 are adjacent near the bottom of the right header; 73 is near the
top of the left one.

**Avoided deliberately:** 32–42 (double as the HDMI/DVI differential pairs through 499 Ω
resistors and ESD clamps), 49 (`LCD_BL`, drives the backlight regulator's enable), 51 (`PA_EN`,
audio amp), 54/55/56 (I²S to the codec), 79 (`WS2812` LED), 80–86 (microSD, 10 kΩ pull-ups),
52/53 (HDMI DDC through 2N7002 level shifters).

⚠️ **Unresolved before probing a real calculator: the HP Prime's LCD interface voltage is
unknown.** These inputs are 3.3 V LVCMOS, whose V_IH is about 2.0 V. If the Prime's bus runs at
1.8 V it will not register reliably and a level shifter is required. Measure before connecting.

Other reference points (not yet wired into any target):

| Signal | Pin | Notes |
|---|---|---|
| `btn[1]` (second button) | 87 | ⚠️ `MODE1` config strap — see above |
| RGB LED | 79 | `WS2812`, has an LED attached |

## Reserved for Phase 3 (parallel RGB LCD header, 40-pin connector)

| Signal | Pins | Notes |
|---|---|---|
| `LCD_R[4:0]` | 38-42 | |
| `LCD_G[5:0]` | 32-37 | |
| `LCD_B[4:0]` | 27-31 | |
| `LCD_DEN` (data enable) | 48 | |
| `LCD_CLK` | 77 | |

These LCD-header numbers come from Sipeed's `rgb_lcd/lcd_480_272/color_bar` example and are
for a 480x272 panel; re-verify against whatever panel is actually sourced for Phase 3 before
relying on them.

The onboard BL616 MCU provides the composite USB device (DirtyJTAG-v2 JTAG + CDC-ACM UART) —
no external USB-serial adapter is needed for the UART path above. Confirmed working; see the
BL616 section near the top of this file for interface selection and gotchas.

Note the BL616 is genuinely a `BL616C-S0-Q2I-QFN40` (schematic `USB_JTAG.kicad_sch`, chip `U5`) —
it emulates an FTDI FT2232H USB descriptor purely for driver compatibility, which is why the host
reports FTDI VID:PID `0403:6010`. Pins 69/70 wire straight to it with no jumper, so do not drive
them externally.
