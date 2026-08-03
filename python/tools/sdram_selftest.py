#!/usr/bin/env python3
"""
Host driver for the SDRAM built-in self test (src/targets/sdram_selftest).

Starts a full-memory write/read-back test on the 8 MB die embedded in the
GW2AR-18 package and reports the result. Follows this repo's PASS:/FAIL: +
exit-code contract.

This is the test simulation cannot substitute for. sdram_ctrl passes against a
strict behavioural model, but that model has no notion of the phase
relationship between the clock the die sees and the data the FPGA drives -- and
a controller with the wrong phase simulates perfectly and reads garbage. Only
real memory can answer it.
"""
import argparse
import sys
import time

import serial

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from serial_selftest import find_port, drain  # noqa: E402

BAUD = 1_000_000
CMD_RESET, CMD_TEST, CMD_STATUS = 0xAA, 0x54, 0x53
HDR_MAGIC, HDR_VERSION, HDR_LEN = 0xA5, 0x03, 11

TOTAL_WORDS = 1 << 21          # 4 banks x 2048 rows x 256 cols
TOTAL_BYTES = TOTAL_WORDS * 4


class Report:
    def __init__(self, raw):
        self.magic, self.version, s = raw[0], raw[1], raw[2]
        self.init_done = bool(s & 0x01)
        self.running   = bool(s & 0x02)
        self.done      = bool(s & 0x04)
        self.failed    = bool(s & 0x08)
        self.pll_lock  = bool(s & 0x10)
        self.words = int.from_bytes(raw[3:7], "little")
        self.errors = int.from_bytes(raw[7:11], "little")
        self.raw = s

    def __str__(self):
        f = "".join(c for c, b in zip("IRDFP", [
            self.init_done, self.running, self.done, self.failed, self.pll_lock]) if b)
        return f"status=0x{self.raw:02x} [{f or '-'}] words={self.words} errors={self.errors}"


def read_report(ser):
    buf = bytearray()
    while len(buf) < HDR_LEN:
        chunk = ser.read(HDR_LEN - len(buf))
        if not chunk:
            raise TimeoutError(f"timed out reading report: {len(buf)} of {HDR_LEN} bytes")
        buf += chunk
    r = Report(bytes(buf))
    if r.magic != HDR_MAGIC or r.version != HDR_VERSION:
        raise ValueError(f"bad report magic/version 0x{r.magic:02x}/0x{r.version:02x} "
                         f"(expected 0x{HDR_MAGIC:02x}/0x{HDR_VERSION:02x})")
    return r


def status(ser):
    ser.write(bytes([CMD_STATUS]))
    ser.flush()
    return read_report(ser)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="seconds to allow the full-memory test")
    args = ap.parse_args()

    with serial.Serial(args.port or find_port(), BAUD, timeout=3) as ser:
        stale = drain(ser)
        if stale:
            print(f"INFO: discarded {stale} bytes of pre-existing traffic")

        try:
            ser.write(bytes([CMD_RESET]))
            ser.flush()
            time.sleep(0.05)
            drain(ser, quiet_for=0.1, limit=1.0)

            r = status(ser)
            if not r.pll_lock:
                print(f"FAIL: PLL not locked ({r})")
                return 1
            if not r.init_done:
                print(f"FAIL: SDRAM controller never completed initialisation ({r})")
                return 1
            print(f"INFO: PLL locked, SDRAM initialised")

            print(f"INFO: testing {TOTAL_WORDS:,} words ({TOTAL_BYTES/1024/1024:.0f} MB), "
                  "write pass then read-back pass")
            t0 = time.time()
            ser.write(bytes([CMD_TEST]))
            ser.flush()

            r = status(ser)
            last = -1
            while not r.done and (time.time() - t0) < args.timeout:
                time.sleep(0.25)
                r = status(ser)
                pct = 100.0 * r.words / TOTAL_WORDS
                if int(pct) != last:
                    last = int(pct)
                    print(f"\r  verifying: {r.words:,}/{TOTAL_WORDS:,} words "
                          f"({pct:5.1f}%)", end="", flush=True)
            print()
            elapsed = time.time() - t0
        except (TimeoutError, ValueError) as e:
            print(f"FAIL: {e}")
            return 1

    if not r.done:
        print(f"FAIL: test did not finish within {args.timeout}s ({r})")
        return 1
    print(f"INFO: {r}")
    print(f"INFO: completed in {elapsed:.2f}s "
          f"({2 * TOTAL_BYTES / elapsed / 1024 / 1024:.1f} MB/s including read-back)")

    if r.words != TOTAL_WORDS:
        print(f"FAIL: verified {r.words:,} words, expected {TOTAL_WORDS:,}")
        return 1
    if r.errors or r.failed:
        print(f"FAIL: {r.errors:,} mismatches out of {TOTAL_WORDS:,} words "
              f"({100.0*r.errors/TOTAL_WORDS:.3f}%)")
        return 1
    print(f"PASS: SDRAM self-test, {TOTAL_WORDS:,} words "
          f"({TOTAL_BYTES/1024/1024:.0f} MB) written and verified, 0 errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
