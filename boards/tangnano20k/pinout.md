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

### The constraint that determines every probe pin

Phase 3 drives a panel from the board's own 40-pin RGB LCD FPC connector and Phase 4 does that
*while* capturing, so those pins can never be shared with the probes. Per the DISPLAY sheet of
`docs/Tang_Nano_20K_3923_Schematics-1.pdf` the connector permanently reserves **twenty** FPGA pins:

| Function | Pins |
|---|---|
| `LCD_R7..R3` | 38, 39, 40, 41, 42 |
| `LCD_G7..G2` | 32, 33, 34, 35, 36, 37 |
| `LCD_B7..B3` | 27, 28, 29, 30, 31 |
| `LCD_CK`, `LCD_HS`, `LCD_VS`, `LCD_DE` | 77, 25, 26, 48 |

plus `LCD_BL` (49) and `LCD_INT0..3` (15–18, shared with the LEDs).

Subtract those, the BL616 pins (13/69/70/75/76/86) and the six LEDs, and the 2×20 headers have
exactly **thirteen** pins left for twelve probes. Five of the thirteen — 52, 53, 54, 55, 56 — are
the device's dedicated SSPI configuration pins, which `gw_sh` refuses to place user I/O on unless
`set_option -use_sspi_as_gpio 1` is given (`src/targets/la_capture/options.tcl`). **Without that
option only eight usable pins remain, and the analyser needs twelve** — so Phase 1's channel count
and Phase 4's LCD output only coexist by reclaiming the SSPI pins. Sipeed's own examples do the
same to reach the I²S codec on 54/55/56.

### Probe wiring reference

HP Prime 45-pin LCD flex → Tang Nano. Flex signal identification is from the scope survey in
`docs/HP Prime LCD Pinout.xlsx`; see `PROGRESS.md` for the arithmetic that supports it.

| Prime flex | Signal | Measured | Channel | FPGA pin | Header | Caveat on the FPGA pin |
|---|---|---|---|---|---|---|
| 7 | DE | 9.8 kHz, 24.7 ms on / 1.96 ms off | `probe[3]` | 51 | R9 | amp `SD_MODE`; also `RPLL2_T_in` (unused — this design uses the *left* PLL) |
| 8 | VSYNC | 37.7 Hz | `probe[2]` | 53 | R19 | ⚠ 2.2 kΩ pull-up to 3V3 (HDMI DDC via 2N7002) |
| 9 | HSYNC | 9.61 kHz | `probe[1]` | 71 | R18 | clean, header only |
| 10 | DOTCLK | 13.1 MHz | `probe[0]` | 80 | R4 | `GCLKT_0`; microSD DAT2 10 kΩ pull-up |
| 11 | D0 | — | `probe[4]` | 72 | R17 | clean, header only |
| 12 | D1 | — | `probe[5]` | 73 | L1 | clean, header only |
| 13 | D2 | — | `probe[6]` | 74 | L2 | clean, header only |
| 14 | D3 | — | `probe[7]` | 85 | L4 | microSD DAT1 10 kΩ pull-up |
| 15 | D4 | — | `probe[8]` | 79 | R14 | `GCLKC_0`; WS2812 data-in via 100 Ω |
| 16 | D5 | — | `probe[9]` | 56 | R7 | SSPI `SO/D1`; amp input, high-Z |
| 17 | D6 | — | `probe[10]` | 54 | R8 | SSPI `DIN/CLKHOLD_N`; amp input, high-Z |
| 18 | D7 | — | `probe[11]` | 55 | R11 | SSPI `SSPI_CS_N/D0`; amp input, high-Z |

**Ground:** tie the pigtail's return to header GND — right header position 2 or 15, or left
header position 20. A common ground is not optional; without it every channel is meaningless.

**Pin 52 is the single spare.** It carries the other 2.2 kΩ DDC pull-up, which is why VSYNC took
53 rather than both going there.

Three placement choices worth not re-litigating:

- **DOTCLK on pin 80** because it is `GCLKT_0`. Nothing clocks off it today, but sampling *on*
  DOTCLK rather than oversampling is how a full frame ever fits in memory, and that needs a real
  global clock buffer. Same lesson as pin 4.
- **VSYNC on pin 53**, the one pin with a 2.2 kΩ pull-up. It makes the Prime's driver sink an
  extra ~1.5 mA when low; if its V_OL rises past the FPGA's 0.8 V V_IL that channel misreads.
  A corrupted 37.7 Hz frame sync is instantly obvious in the decode; a corrupted data bit is
  silent and yields plausible-looking wrong pixels.
- **Pin 51 despite being the amp's shutdown pin**, because the alternative (52) carries the second
  DDC pull-up. With no speaker on J4 the amp is inert, and `PULL_MODE=DOWN` holds it shut down
  whenever nothing is connected.

### ☠️ Prime flex pins that will destroy the FPGA

Do not connect any of these to anything on the Tang Nano:

| Flex pins | Why |
|---|---|
| 32–42 | TFT gate-driver region: 16.88 V, −8.3 V, −3.3 V rails and 15.4 Vpp swings at 26.3 kHz |
| 3, 4 | 5.5 V |
| 25, 31 | 5 V |
| 35, 36 | 16.88 V / −8.3 V |

Flex pins 19–21 read as noisy ground and 1/2/5/6/45 are ground.

### ⚠️ Unresolved: the Prime's logic level

The scope survey records amplitudes for flex pins 27–29 ("3.3 v logic") and for the 32–42 group,
but for **pins 7–18 it records only frequencies**. These FPGA inputs are 3.3 V LVCMOS with
V_IH ≈ 2.0 V:

- 3.3 V → wire directly.
- 1.8 V → will not register; a level shifter is required. Flex pin 24 reading 2 V hints there may
  be a lower-voltage domain on this flex.

**Measure the logic HIGH level on flex pin 10 (DOTCLK) before connecting anything.** It toggles
continuously, so it is the easiest to read cleanly.

### Worth capturing later: flex pins 27, 28, 29

Three "3.3 v logic" lines, isolated from the video group by the noisy-ground block at 19–21.
Shape and count match an ILI9322's SPI configuration interface (CS / SCL / SDI). Capturing them
at power-on would yield the controller's actual register settings — mode, porches, colour format
— rather than inferring them from video timing, which would de-risk Phase 3 considerably.

Other reference points (not yet wired into any target):

| Signal | Pin | Notes |
|---|---|---|
| `btn[1]` (second button) | 87 | ⚠️ `MODE1` config strap — see above |
| RGB LED | 79 | `WS2812`, has an LED attached |

## Reserved for Phase 3 (parallel RGB LCD header, 40-pin connector)

**Verified 2026-08-02 against the DISPLAY sheet of `docs/Tang_Nano_20K_3923_Schematics-1.pdf`,
which is the board's own wiring and therefore panel-independent.** The previous version of this
table came from Sipeed's `rgb_lcd/lcd_480_272/color_bar` example and carried a "re-verify before
relying on this" caveat; it is now confirmed and the low-order colour bits are documented.

| Signal | FPGA pins | Notes |
|---|---|---|
| `LCD_R7..R3` | 38, 39, 40, 41, 42 | R2..R0 are tied to GND at the connector — 5 bits of red |
| `LCD_G7..G2` | 32, 33, 34, 35, 36, 37 | G1..G0 tied to GND — 6 bits of green |
| `LCD_B7..B3` | 27, 28, 29, 30, 31 | B2..B0 tied to GND — 5 bits of blue |
| `LCD_CK` | 77 | also `GCLKT_1` |
| `LCD_HS` | 25 | |
| `LCD_VS` | 26 | |
| `LCD_DE` | 48 | |
| `LCD_BL` | 49 | backlight regulator enable |
| `LCD_INT0..3` | 15, 16, 17, 18 | ⚠ shared with `leds[0..3]` |

So the connector is a **RGB565** interface — 5:6:5 is a property of the board's wiring, not of
whichever panel is plugged in. Twenty pins, plus the backlight.

⚠️ `LCD_INT0..3` share pins 15–18 with four of the six onboard LEDs. If Phase 3's panel needs
those interrupt lines (touch, typically), those LEDs must be given up. `la_capture` uses all six
as status indicators today; nothing has had to choose yet.

The onboard BL616 MCU provides the composite USB device (DirtyJTAG-v2 JTAG + CDC-ACM UART) —
no external USB-serial adapter is needed for the UART path above. Confirmed working; see the
BL616 section near the top of this file for interface selection and gotchas.

Note the BL616 is genuinely a `BL616C-S0-Q2I-QFN40` (schematic `USB_JTAG.kicad_sch`, chip `U5`) —
it emulates an FTDI FT2232H USB descriptor purely for driver compatibility, which is why the host
reports FTDI VID:PID `0403:6010`. Pins 69/70 wire straight to it with no jumper, so do not drive
them externally.
