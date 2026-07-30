#!/usr/bin/env python3
"""
Host-side hardware self-test: talks to the Tang Nano 20K's onboard BL616
CDC-ACM UART bridge, sends a resync command, and verifies the streamed byte
sequence matches the FPGA's LFSR mock pattern bit-for-bit. Mirrors the
sim/build PASS/FAIL + exit-code contract so an agent can drive it identically.
"""
import argparse
import sys

import serial
import serial.tools.list_ports

CMD_RESYNC = 0xAA
SEED = 0x01
BAUD = 1_000_000


def lfsr_next(v: int) -> int:
    fb = ((v >> 7) ^ (v >> 5) ^ (v >> 4) ^ (v >> 3)) & 1
    return ((v << 1) | fb) & 0xFF


def find_port() -> str:
    # TODO: once the board is connected, run `python3 -m serial.tools.list_ports -v`
    # and hardcode the BL616's actual VID:PID here for robust auto-detection.
    ports = list(serial.tools.list_ports.comports())
    if not ports:
        raise SystemExit("FAIL: no serial ports found; pass --port explicitly")
    return ports[0].device


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=BAUD)
    ap.add_argument("--count", type=int, default=256)
    args = ap.parse_args()

    port = args.port or find_port()
    with serial.Serial(port, args.baud, timeout=2) as ser:
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
