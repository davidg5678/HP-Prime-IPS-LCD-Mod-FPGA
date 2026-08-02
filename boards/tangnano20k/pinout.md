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
| `uart_rx` | 71 | temporary Arduino Uno bridge, host → FPGA (was pin 70/BL616; see `arduino_bridge.md`) |
| `uart_tx` | 72 | temporary Arduino Uno bridge, FPGA → host (was pin 69/BL616; see `arduino_bridge.md`) |
| `leds[0..5]` | 15, 16, 17, 18, 19, 20 | Onboard LEDs, active-low |

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
no external USB-serial adapter is needed for the UART path above.

**2026-08-02 update:** in practice, the BL616's UART interface is not currently usable from
macOS (the built-in `AppleUSBFTDI` kernel driver claims both FTDI-emulated interfaces
exclusively). Until that's resolved, hardware self-tests use a temporary Arduino Uno
USB-serial bridge instead, on pins 71/72 rather than the BL616-wired 69/70 (which are hard-wired
straight to the BL616 and would electrically contend with an external driver) — see
`boards/tangnano20k/arduino_bridge.md`.
