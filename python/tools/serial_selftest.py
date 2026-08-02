#!/usr/bin/env python3
"""
Host-side hardware self-test: talks to the Tang Nano 20K's onboard BL616 UART
(FPGA pins 69/70 -- no external bridge), sends a resync command, and verifies
the burst matches the FPGA's LFSR mock pattern bit-for-bit. Mirrors the
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
BAUD = 1_000_000  # must match the BAUD localparam in bringup_selftest_top.v

# The onboard BL616 debug MCU emulates an FTDI FT2232H (hence the FTDI VID:PID
# despite being Bl616 silicon -- see PROGRESS.md). It exposes two interfaces:
#   interface A -> DirtyJTAG-v2, used by openFPGALoader. NOT a UART.
#   interface B -> the UART wired to FPGA pins 69/70. This is the one we want.
# Both enumerate with identical VID:PID, serial and location; macOS
# distinguishes them only by an interface index appended to the device name
# (...170 = A, ...171 = B), so sorting by device name and taking the last is
# the only available discriminator.
BL616_VID_PID = (0x0403, 0x6010)


def lfsr_next(v: int) -> int:
    fb = ((v >> 7) ^ (v >> 5) ^ (v >> 4) ^ (v >> 3)) & 1
    return ((v << 1) | fb) & 0xFF


def find_port() -> str:
    # Must not fall back to "first port in the list" -- on macOS that is
    # reliably /dev/cu.Bluetooth-Incoming-Port, which opens fine and then
    # silently returns nothing, producing a confusing 0-byte timeout.
    ports = list(serial.tools.list_ports.comports())
    bl616 = sorted(
        (p for p in ports if (p.vid, p.pid) == BL616_VID_PID),
        key=lambda p: p.device,
    )
    if len(bl616) >= 2:
        return bl616[-1].device  # interface B
    if len(bl616) == 1:
        # Only one interface enumerated -- unusual. Use it, but say so, since
        # if it is interface A the failure below would look like a dead link.
        print(
            f"INFO: only one BL616 interface enumerated ({bl616[0].device}); "
            "expected two (A=JTAG, B=UART)",
            file=sys.stderr,
        )
        return bl616[0].device
    if not ports:
        raise SystemExit("FAIL: no serial ports found; pass --port explicitly")
    listing = "\n".join(
        f"  {p.device}  vid={(p.vid or 0):04x}:{(p.pid or 0):04x}  {p.description}"
        for p in ports
    )
    raise SystemExit(
        "FAIL: no BL616 debugger found (expected VID:PID 0403:6010); "
        f"pass --port explicitly. Ports seen:\n{listing}"
    )


def drain(ser: serial.Serial, quiet_for: float = 0.3, limit: float = 3.0) -> int:
    """Read until the line has been quiet for `quiet_for` seconds.

    Necessary because the BL616 emits its own firmware log on this same
    endpoint while JTAG programming (e.g. ' Write: 0x400000'), so a run started
    immediately after `make flash-sram` can otherwise read log text and report
    it as a data mismatch.
    """
    total = 0
    deadline = time.time() + limit
    last = time.time()
    while time.time() < deadline and time.time() - last < quiet_for:
        chunk = ser.read(4096)
        if chunk:
            total += len(chunk)
            last = time.time()
    return total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=BAUD)
    ap.add_argument("--count", type=int, default=BURST_LEN)
    args = ap.parse_args()

    if args.count > BURST_LEN:
        # Otherwise this surfaces as a bare timeout, which reads like a broken
        # link rather than a protocol limit.
        print(f"FAIL: --count {args.count} exceeds the FPGA's BURST_LEN "
              f"({BURST_LEN}); one CMD_RESYNC arms exactly {BURST_LEN} bytes")
        return 1

    port = args.port or find_port()
    with serial.Serial(port, args.baud, timeout=2) as ser:
        stale = drain(ser)
        if stale:
            print(f"INFO: discarded {stale} bytes of pre-existing traffic "
                  "(BL616 programming log)")
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
