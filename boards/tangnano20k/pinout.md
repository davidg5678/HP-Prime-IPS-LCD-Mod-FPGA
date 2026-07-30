# Tang Nano 20K — Pin Reference

Device: Gowin `GW2AR-LV18QN88C8/I7` (device name `GW2AR-18C`). 20736 LUT4, 15552 FF,
828Kbit block SRAM, 64Mbit onboard SDRAM, 64Mbit flash.

Verified by cross-referencing Sipeed's `TangNano-20K-example` repo `.cst` files against
`litex-boards`' Tang Nano 20K platform file.

## Used by `bringup_selftest` (proto-phase-1)

| Signal | Pin | Notes |
|---|---|---|
| `clk` | 4 | 27 MHz onboard oscillator |
| `rst` | 88 | Reset button; idle-high, verify active-low assumption on first bring-up |
| `uart_rx` | 70 | BL616 CDC-ACM bridge, host → FPGA |
| `uart_tx` | 69 | BL616 CDC-ACM bridge, FPGA → host |
| `leds[0..5]` | 15, 16, 17, 18, 19, 20 | Onboard LEDs, active-low |

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
