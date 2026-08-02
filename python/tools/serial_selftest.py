#!/usr/bin/env python3
"""
Host-side hardware self-test: talks to the Tang Nano 20K's onboard BL616
CDC-ACM UART bridge, sends a resync command, and verifies the streamed byte
sequence matches the FPGA's LFSR mock pattern bit-for-bit. Mirrors the
sim/build PASS/FAIL + exit-code contract so an agent can drive it identically.
"""
import argparse
import sys
import time

import serial
import serial.tools.list_ports

CMD_RESYNC = 0xAA
SEED = 0x01
BURST_LEN = 256  # must match BURST_LEN in bringup_selftest_top.v
# Host<->Arduino link speed (USB_BAUD in the sketch). NOT the FPGA link speed:
# the bridge deliberately runs its bit-banged FPGA side slower (FPGA_BAUD=38400).
BAUD = 115_200  # see boards/tangnano20k/arduino_bridge.md
ARDUINO_VIDS = (0x2341, 0x2a03)  # genuine Arduino (LLC and SA); CH340 clones need --port
# Opening the port asserts DTR, which auto-resets the Uno; the bootloader then
# holds the line for ~1.5s before the relay sketch starts. Commands sent during
# that window are silently lost.
UNO_RESET_SETTLE_S = 2.5


def lfsr_next(v: int) -> int:
    fb = ((v >> 7) ^ (v >> 5) ^ (v >> 4) ^ (v >> 3)) & 1
    return ((v << 1) | fb) & 0xFF


def find_port() -> str:
    # Must not fall back to "first port in the list" -- on macOS that is
    # reliably /dev/cu.Bluetooth-Incoming-Port, which opens fine and then
    # silently returns nothing, producing a confusing 0-byte timeout.
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
        "FAIL: could not unambiguously identify the bridge port; "
        f"pass --port explicitly. Ports seen:\n{listing}"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=BAUD)
    ap.add_argument("--count", type=int, default=256)
    ap.add_argument("--settle", type=float, default=UNO_RESET_SETTLE_S,
                    help="seconds to wait after opening the port for the Uno to finish auto-resetting")
    args = ap.parse_args()

    if args.count > BURST_LEN:
        # Otherwise this surfaces as a bare timeout, which reads like a broken
        # link rather than a protocol limit.
        print(f"FAIL: --count {args.count} exceeds the FPGA's BURST_LEN "
              f"({BURST_LEN}); one CMD_RESYNC arms exactly {BURST_LEN} bytes")
        return 1

    port = args.port or find_port()
    with serial.Serial(port, args.baud, timeout=2) as ser:
        time.sleep(args.settle)
        ser.reset_input_buffer()
        ser.write(bytes([CMD_RESYNC]))
        expected = SEED
        for i in range(args.count):
            b = ser.read(1)
            if len(b) != 1:
                print(f"FAIL: timed out after {i} bytes (expected {args.count})")
                return 1
            if b[0] != expected:
                print(f"FAIL: byte {i} mismatch: expected=0x{expected:02x} got=0x{b[0]:02x}")
                return 1
            expected = lfsr_next(expected)
    print(f"PASS: hardware serial self-test, {args.count} bytes verified, 0 errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
