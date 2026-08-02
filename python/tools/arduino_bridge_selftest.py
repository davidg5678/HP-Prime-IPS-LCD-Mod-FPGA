#!/usr/bin/env python3
"""
Arduino-bridge loopback self-test (temporary bring-up tooling).
Verifies the Arduino Uno USB-serial bridge + resistor divider + a physical
jumper across FPGA header pins 69/70 forms a working signal path, before
trusting it to run serial_selftest.py against the FPGA. See
boards/tangnano20k/arduino_bridge.md for wiring. Mirrors this repo's
PASS/FAIL + exit-code contract. Run with the FPGA unplugged and pins 69/70
jumpered together.
"""
import argparse
import sys

import serial
import serial.tools.list_ports

BAUD = 115_200  # matches the sketch's USB_BAUD (hardware UART side), not its FPGA_BAUD
ARDUINO_VIDS = (0x2341, 0x2a03)  # genuine Arduino (LLC and SA); CH340 clones need --port
PAYLOAD = bytes(range(256))


def find_port() -> str:
    ports = list(serial.tools.list_ports.comports())
    arduino = [p for p in ports if p.vid in ARDUINO_VIDS]
    if len(arduino) == 1:
        return arduino[0].device
    if not ports:
        raise SystemExit("FAIL: no serial ports found; pass --port explicitly")
    listing = "\n".join(
        f"  {p.device}  vid={(p.vid or 0):04x}  {p.description}" for p in ports
    )
    raise SystemExit(
        "FAIL: could not unambiguously identify the Arduino bridge; "
        f"pass --port explicitly. Ports seen:\n{listing}"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=BAUD)
    args = ap.parse_args()

    port = args.port or find_port()
    with serial.Serial(port, args.baud, timeout=2) as ser:
        ser.reset_input_buffer()
        ser.write(PAYLOAD)
        echoed = ser.read(len(PAYLOAD))
        if len(echoed) != len(PAYLOAD):
            print(
                f"FAIL: only {len(echoed)}/{len(PAYLOAD)} bytes looped back "
                f"(timeout) at {args.baud} baud -- check wiring/jumper, or "
                f"stock 16u2 firmware may not support this baud; try --baud 115200"
            )
            return 1
        if echoed != PAYLOAD:
            i = next(k for k in range(len(PAYLOAD)) if PAYLOAD[k] != echoed[k])
            print(f"FAIL: byte {i} mismatch: sent=0x{PAYLOAD[i]:02x} got=0x{echoed[i]:02x}")
            return 1
    print(f"PASS: arduino bridge loopback, {len(PAYLOAD)} bytes verified, 0 errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
