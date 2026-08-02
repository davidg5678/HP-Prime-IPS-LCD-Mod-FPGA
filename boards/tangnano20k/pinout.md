# Tang Nano 20K — Pin Reference

Device: Gowin `GW2AR-LV18QN88C8/I7` (device name `GW2AR-18C`). 20736 LUT4, 15552 FF,
828Kbit block SRAM, 64Mbit onboard SDRAM, 64Mbit flash.

Verified by cross-referencing Sipeed's `TangNano-20K-example` repo `.cst` files against
`litex-boards`' Tang Nano 20K platform file.

## Used by `bringup_selftest` (proto-phase-1)

| Signal | Pin | Notes |
|---|---|---|
| `clk` | 4 | 27 MHz onboard oscillator |
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

If a physical reset button is ever wanted, the second button on **pin 87** is the candidate —
but verify it has no dual-purpose function first.

Other reference points (not yet wired into any target):

| Signal | Pin | Notes |
|---|---|---|
| `btn[1]` (second button) | 87 | |
| RGB LED | 79 | |

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
