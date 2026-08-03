#!/usr/bin/env python3
"""
Capture a whole frame of the HP Prime's LCD bus into SDRAM and decode it.

Arms the frame_capture bitstream, which starts on the next VSYNC falling edge
so the capture is frame-aligned by construction, drains the packed samples over
the 1 Mbaud UART, and reconstructs the 320x240 image.

Sample format (see src/targets/frame_capture/frame_capture_top.v): each 32-bit
word holds two 11-bit samples, one per DOTCLK --
    even = word[10:0], odd = word[26:16]
    bit 0 HSYNC, bit 1 VSYNC, bit 2 DE, bits 10..3 = D0..D7
DOTCLK itself is not stored: in synchronous capture every sample IS a DOTCLK.

Protocol facts used here are all measured; see docs/prime_lcd_protocol.md.
"""
import argparse
import sys
import time

import serial

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from serial_selftest import find_port, drain  # noqa: E402

BAUD = 1_000_000
CMD_RESET, CMD_ARM, CMD_STATUS, CMD_READ = 0xAA, 0x41, 0x53, 0x47
HDR_MAGIC, HDR_VERSION, HDR_LEN = 0xA5, 0x04, 12

CAP_WORDS = 180_000          # must match the target's CAP_WORDS parameter
CHUNK = 4096                 # words per read request; 16 KB in flight at a time

ACTIVE_PIXELS, BYTES_PER_PIXEL = 320, 3


class Report:
    def __init__(self, raw):
        self.magic, self.version, s = raw[0], raw[1], raw[2]
        self.pll_lock   = bool(s & 0x01)
        self.sdram_init = bool(s & 0x02)
        self.armed      = bool(s & 0x04)
        self.capturing  = bool(s & 0x08)
        self.done       = bool(s & 0x10)
        self.overrun    = bool(s & 0x20)
        self.words = int.from_bytes(raw[4:8], "little")
        self.runts = int.from_bytes(raw[8:10], "little")
        self.reply = int.from_bytes(raw[10:12], "little")
        self.raw = s

    def __str__(self):
        f = "".join(c for c, b in zip("PSACDO", [
            self.pll_lock, self.sdram_init, self.armed,
            self.capturing, self.done, self.overrun]) if b)
        return f"status=0x{self.raw:02x} [{f or '-'}] words={self.words} runts={self.runts}"


def _read_exact(ser, n, what):
    buf = bytearray()
    while len(buf) < n:
        chunk = ser.read(n - len(buf))
        if not chunk:
            raise TimeoutError(f"timed out reading {what}: {len(buf)} of {n} bytes")
        buf += chunk
    return bytes(buf)


def report(ser):
    r = Report(_read_exact(ser, HDR_LEN, "report"))
    if r.magic != HDR_MAGIC or r.version != HDR_VERSION:
        raise ValueError(f"bad report 0x{r.magic:02x}/0x{r.version:02x}")
    return r


def status(ser):
    ser.write(bytes([CMD_STATUS])); ser.flush()
    return report(ser)


def read_window(ser, start, count):
    ser.write(bytes([CMD_READ]) + start.to_bytes(4, "little")
              + count.to_bytes(2, "little"))
    ser.flush()
    r = report(ser)
    body = _read_exact(ser, r.reply * 4, f"{r.reply} words at {start}")
    return r, [int.from_bytes(body[i:i+4], "little") for i in range(0, len(body), 4)]


def unpack(words):
    out = []
    for w in words:
        out.append(w & 0x7FF)
        out.append((w >> 16) & 0x7FF)
    return out


def decode(samples):
    """Split into lines on DE, and each line into RGB pixels (3 DOTCLKs each)."""
    lines, run = [], []
    prev_de = 0
    for s in samples:
        de = (s >> 2) & 1
        if de:
            run.append((s >> 3) & 0xFF)
        elif prev_de and run:
            lines.append(run)
            run = []
        prev_de = de
    if run:
        lines.append(run)

    pixels, stats = [], []
    for i, ln in enumerate(lines):
        px = [tuple(ln[j:j+3]) for j in range(0, len(ln) - 2, 3)]
        stats.append((len(ln), len(px)))
        pixels.append(px)
    return pixels, stats


def write_ppm(path, rows):
    w = max((len(r) for r in rows), default=0)
    h = len(rows)
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        for r in rows:
            row = bytearray()
            for i in range(w):
                row += bytes(r[i]) if i < len(r) else b"\0\0\0"
            f.write(row)
    return w, h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--words", type=int, default=CAP_WORDS,
                    help="words to read back (default: the whole capture)")
    ap.add_argument("--ppm", default=None, help="write the decoded frame here")
    ap.add_argument("--timeout", type=float, default=10.0)
    args = ap.parse_args()

    with serial.Serial(args.port or find_port(), BAUD, timeout=5) as ser:
        stale = drain(ser)
        if stale:
            print(f"INFO: discarded {stale} bytes of pre-existing traffic")
        try:
            ser.write(bytes([CMD_RESET])); ser.flush()
            time.sleep(0.05)
            drain(ser, quiet_for=0.1, limit=1.0)

            r = status(ser)
            if not r.pll_lock or not r.sdram_init:
                print(f"FAIL: not ready ({r})")
                return 1
            print(f"INFO: PLL locked, SDRAM initialised")

            ser.write(bytes([CMD_ARM])); ser.flush()
            t0 = time.time()
            r = status(ser)
            while not r.done and (time.time() - t0) < args.timeout:
                time.sleep(0.02)
                r = status(ser)
            if not r.done:
                print(f"FAIL: capture did not complete within {args.timeout}s ({r})")
                return 1
            print(f"INFO: {r}")
            if r.overrun:
                print("FAIL: overrun -- samples were lost between the sampler and SDRAM")
                return 1

            n = min(args.words, r.words)
            print(f"INFO: draining {n:,} words ({n*4/1024:.0f} KB) at 1 Mbaud, "
                  f"about {n*4*10/1e6:.0f}s")
            words, t1 = [], time.time()
            while len(words) < n:
                want = min(CHUNK, n - len(words))
                _, chunk = read_window(ser, len(words), want)
                if not chunk:
                    print(f"FAIL: empty reply at word {len(words)}")
                    return 1
                words.extend(chunk)
                pct = 100.0 * len(words) / n
                print(f"\r  {len(words):,}/{n:,} ({pct:5.1f}%)", end="", flush=True)
            print(f"\nINFO: drained in {time.time()-t1:.1f}s")
        except (TimeoutError, ValueError) as e:
            print(f"FAIL: {e}")
            return 1

    samples = unpack(words)
    pixels, stats = decode(samples)
    full = [p for p, (dots, npx) in zip(pixels, stats) if npx == ACTIVE_PIXELS]
    print(f"INFO: {len(samples):,} samples -> {len(pixels)} DE runs, "
          f"{len(full)} of them a full {ACTIVE_PIXELS} pixels")
    if stats:
        odd = [(d, p) for d, p in stats if p != ACTIVE_PIXELS]
        if odd:
            print(f"INFO: {len(odd)} partial run(s), e.g. {odd[:3]} (DOTCLKs, pixels)")

    if args.ppm and full:
        w, h = write_ppm(args.ppm, full)
        print(f"INFO: wrote {args.ppm} ({w}x{h})")

    if len(full) < 200:
        print(f"FAIL: only {len(full)} complete lines recovered, expected about 240")
        return 1
    print(f"PASS: frame captured and decoded, {len(full)} lines of "
          f"{ACTIVE_PIXELS} pixels, {r.runts} runt edges rejected in hardware")
    return 0


if __name__ == "__main__":
    sys.exit(main())
