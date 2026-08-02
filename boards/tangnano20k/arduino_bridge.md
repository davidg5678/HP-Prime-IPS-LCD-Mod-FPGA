# Arduino Uno UART Bridge (temporary bring-up workaround)

**Why this exists:** the Tang Nano 20K's onboard BL616 debugger is not currently usable as a
UART bridge from macOS — its FTDI-emulated USB interfaces are both claimed exclusively by the
built-in `AppleUSBFTDI` kernel driver. See `boards/tangnano20k/pinout.md` for the pin reference
this supplements, and `PROGRESS.md` for the full diagnostic trail. This doc, the
`arduino/fpga_uart_bridge/` sketch, and the `arduino_bridge_selftest.py` script are a temporary
workaround — remove once the BL616 UART path is resolved.

**Pins 71/72, not 69/70:** the schematic shows pins 69/70 are hard-wired directly to the BL616's
own UART pins with no jumper in between — driving them externally would put the Arduino's driver
in electrical contention with the BL616's. `bringup_selftest`'s `uart_rx`/`uart_tx` are mapped to
pins 71/72 instead (see `bringup_selftest.cst`); the diagram and table below use those.

**Sketch-based relay, not a bare 16u2 adapter:** the first approach tried was grounding the Uno's
`RESET` pin to disable the ATmega328p and use the 16u2 USB-serial chip as a bare pass-through on
D0/D1. That checked out in an Arduino-only loopback test, but stopped responding to host control
once wired to the FPGA and never got diagnosed further (see `PROGRESS.md`). Current approach
instead runs a normal sketch on the 328p (`arduino/fpga_uart_bridge/fpga_uart_bridge.ino`) that
relays bytes between hardware `Serial` (the USB link to the Mac, via the 16u2 as usual) and a
`SoftwareSerial` link on spare pins D2/D3 to the FPGA — since the Uno's one hardware UART is
already committed to the USB connection. `RESET` is **not** grounded; the 328p runs normally.

## Baud: the two links run at DIFFERENT rates (this is deliberate)

| Link | Rate | Set by |
|---|---|---|
| Mac ↔ Uno (hardware UART, via 16u2) | **115200** | `USB_BAUD` in `fpga_uart_bridge.ino` = `BAUD` in `serial_selftest.py` / `arduino_bridge_selftest.py` |
| Uno ↔ FPGA (bit-banged SoftwareSerial) | **38400** | `FPGA_BAUD` in `fpga_uart_bridge.ino` = `BAUD` localparam in `bringup_selftest_top.v` |

Running *both* sides at 115200 loses data, and not marginally — structurally. `SoftwareSerial`'s
RX ISR holds interrupts disabled for a whole byte time, which blocks the hardware USART's `UDRE`
interrupt and stalls outgoing TX. The outbound rate is therefore strictly lower than the inbound
rate, so a sustained FPGA burst overruns the 64-byte buffer no matter how large you make it.
Measured symptom: exactly one byte *dropped* (not corrupted) every ~116 bytes. Slowing only the
bit-banged side gives the relay 3x headroom.

This is a limitation of *this bridge*, not of the FPGA — if the BL616 path or a real USB-serial
adapter is ever adopted, both sides can go back up. If you change either rate, change its matching
pair above together, then `make build && make flash-sram` and re-upload the sketch.

## Signal path

```
Arduino Uno (5V logic)                              Tang Nano 20K (3.3V LVCMOS)
┌──────────────────┐                                ┌──────────────────────┐
│ Serial (D0/D1) ───┼── USB to Mac (unchanged)        │                      │
│                   │                                │                      │
│ D3 (softSerial   ─┼──[1k]──●──[2k]──GND             │                      │
│      TX, 5V)      │        │  (3.33V divider)       │                      │
│                   │        └───────────────────────►│ pin 71 (uart_rx)     │
│                   │                                │                      │
│ D2 (softSerial   ◄┼────────────────────────────────┤ pin 72 (uart_tx)     │
│      RX) ◄────────┼─   (3.3V into 5V input: fine)    │                      │
│ GND ──────────────┼────────────────────────────────┤ any GND              │
│ 5V                │  NOT CONNECTED                   │                      │
└──────────────────┘                                └──────────────────────┘
```

The sketch (`arduino/fpga_uart_bridge/fpga_uart_bridge.ino`) just copies bytes in both directions
between `Serial` and `fpgaSerial` — it doesn't interpret them.

## Arduino setup

1. Install `arduino-cli` and the AVR core (one-time):
   ```
   brew install arduino-cli
   arduino-cli core update-index
   arduino-cli core install arduino:avr
   ```
2. Compile and upload:
   ```
   arduino-cli compile --fqbn arduino:avr:uno arduino/fpga_uart_bridge
   arduino-cli upload -p <arduino-port> --fqbn arduino:avr:uno arduino/fpga_uart_bridge
   ```
   Upload uses the normal auto-reset bootloader sequence, so `RESET` must **not** be grounded
   during upload (or ever, with this approach).

## Wiring table

| Arduino Uno pin | Connects to | Tang Nano 20K pin | Notes |
|---|---|---|---|
| `D3` (softSerial TX, 5V out) | through divider (below) | 71 (`uart_rx`) | needs step-down, see below |
| `D2` (softSerial RX, 5V-logic in) | direct wire | 72 (`uart_tx`) | 3.3V into 5V input is fine in practice |
| `GND` | direct wire | any board GND | required common reference |
| `5V` | **not connected** | — | never tie to the FPGA's 3.3V rail |
| `D0`/`D1`/`RESET` | unused by this approach | — | free for normal USB/upload use |

## Voltage divider (Arduino `D3` → FPGA pin 71 only)

The FPGA's I/O pins are LVCMOS33 (3.3V-only, not 5V-tolerant) — the Arduino's 5V output on `D3`
must be stepped down before it reaches pin 71. The reverse direction (`D2` reading the FPGA's
3.3V `uart_tx`) needs no protection: 3.3V comfortably clears a 5V AVR's ~3.0V logic-high
threshold.

R1 = 1kΩ in series from `D3` to a node, R2 = 2kΩ from that node to `GND`, node → pin 71:

```
D3 ──[R1 1k]──●──[R2 2k]── GND
              │
              └── pin 71
```

`Vout = 5V × R2/(R1+R2) = 5V × 2/3 ≈ 3.33V`. Any resistors in a 1:2 ratio work (e.g. 10k/20k
draws less current, ~0.17mA vs. ~1.67mA at 1k/2k — both negligible for an AVR pin).

**Verify with a multimeter before connecting to the FPGA for the first time:** with the sketch
running and the link idle, the node feeding pin 71 should read ~3.3V, not near 0V or near 5V.

## IMPORTANT: contention warning for the loopback test

The bridge loopback test (below) shorts FPGA pins 71 and 72 together at the header. **Keep the
Tang Nano's USB cable unplugged while running it.** If the board is powered and running
`bringup_selftest`, its own `uart_tx` driver on pin 72 will fight the Arduino's divider output on
pin 71 through that same short. The header pins are used purely as a passive jumper point for
this test — only plug in / flash the FPGA afterwards, for the real hardware self-test.

## Test procedure

1. Upload the sketch (above). Wire per the table above. Tang Nano USB cable **unplugged**.
2. Jumper FPGA header pin 71 to pin 72 (the loopback point).
3. `make selftest-bridge` (add `PORT=/dev/cu.usbmodemXXXX` if auto-detection is ambiguous — see
   `python/tools/arduino_bridge_selftest.py --help`). Must print
   `PASS: arduino bridge loopback, 256 bytes verified, 0 errors` before proceeding.
4. Remove the 71–72 jumper. Plug in / flash the Tang Nano (`make flash-sram`).
5. `make selftest-hw PORT=<arduino-port>` against the real FPGA design.

## Protocol: burst-on-demand, not free-running

The FPGA does **not** stream continuously. `CMD_RESYNC` (`0xAA`) reloads the LFSR seed and arms
exactly `BURST_LEN` = 256 bytes; the line is idle high otherwise. Two reasons, both load-bearing:

1. **Framing.** With no inter-frame idle, a receiver cannot establish framing — a data bit's
   falling edge is indistinguishable from a start bit. The burst's leading idle gap gives every
   receiver an unambiguous sync point, so byte 0 is *always* SEED (`0x01`).
2. **Bridge headroom.** A gap-free stream pins the `SoftwareSerial` receiver at 100% duty.

Consequences when driving this by hand:
- `serial_selftest.py --count` must be **≤ 256**; the script now rejects larger values explicitly
  rather than surfacing it as a bare timeout.
- **Drain the full 256-byte burst before sending the next command**, or the leftovers arrive first
  and look like corruption. `serial_selftest.py` does this correctly.
- Mode commands (`0x4D` mock / `0x52` real) only change *which* source feeds the next burst — they
  don't arm one. Send the mode byte, then `0xAA`.

## Uno auto-reset on port open

Opening the Uno's serial port asserts DTR, which **resets the board**; the bootloader then holds
the line for ~1.5s and swallows anything sent during that window. `serial_selftest.py` waits
`--settle` seconds (default 2.5) after opening before sending. Any ad-hoc `python3 -c` snippet
must do the same or it will appear to get no response.

## Bring-up diagnostic LED

`bringup_selftest_top.v` has a sticky `leds[3]` (pin 18) indicator: it latches on permanently the
instant the FPGA receives even one valid UART byte since reset, and never turns back off. Useful
for confirming the RX direction (Mac → Arduino → FPGA) is working without needing to catch a
transient LED state at the right moment, unlike `leds[1]` (current mock/real mode, a snapshot
that requires knowing which state to expect).
