#!/usr/bin/env python3
"""
Decode an la_capture trace of the HP Prime's LCD bus into pixels.

The interface parameters below are not assumptions -- every one was measured
from a real capture on 2026-08-02 and the derivation is in PROGRESS.md.

    DOTCLK          13.29 MHz, ~53% duty
    3 DOTCLKs per pixel   (960 per active line = 320 pixels exactly)
    line            102.4 us = 9.76 kHz, 1361 DOTCLKs (960 active + 401 blanking)
    HSYNC           active low, ~1 DOTCLK wide
    DE              active high, 72.25 us
    VSYNC           active low, 37.7 Hz
    data            changes on the DOTCLK FALLING edge, so it is stable across
                    the rising edge -- latch there
    component order R, G, B -- confirmed with a red screen, which captured as
                    320 px of ff 00 00 with the triplet phase already pinned
                    independently by the greyscale captures

Usage
    python3 python/tools/decode_prime.py --capture captures/x.json
    python3 python/tools/decode_prime.py --live --ppm captures/screen.ppm
"""
import argparse
import json
import sys

C_DOTCLK, C_HSYNC, C_VSYNC, C_DE = 0, 1, 2, 3
BYTES_PER_PIXEL = 3          # measured: 960 DOTCLKs / 320 px
ACTIVE_PIXELS = 320

# Sampling offset in samples after the DOTCLK rising edge. Measured by sweeping
# 0..7 against "how many pixels come out with R != G != B": offsets 0-3 give
# ZERO mixed pixels, 4+ give tens. Data changes ~4.3 samples after the rising
# edge (i.e. on the falling edge), so anything from 0 to 3 is inside the valid
# window; 0 is the centre of the safest region.
#
# This is worth stating because the obvious choice -- latch midway between
# consecutive rising edges -- is WRONG here. At 53% duty the midpoint lands
# essentially on the falling edge, exactly where the data changes, and produces
# a decode that looks almost right: solid areas are fine and only the pixels at
# colour boundaries come out corrupted, which reads as anti-aliasing rather
# than as a bug.
SAMPLE_OFFSET = 0

# Minimum spacing, in samples, between two DOTCLK rising edges for the second
# to be believed. The nominal period is 108 MHz / 13.29 MHz = 8.1 samples, so
# nothing real can arrive sooner than about half that.
#
# This is not defensive padding, it fixes a measured failure. Oversampling an
# asynchronous 13.29 MHz clock only 8.1x means the 2-FF synchroniser
# occasionally resolves a metastable edge into a runt: 2 in 8064 half-periods
# were <= 1 sample wide. One spurious rising edge per ~1000 is enough to give a
# line 961 DOTCLKs instead of 960, and since pixels are grouped in threes, every
# triplet boundary after it shifts by one byte -- one bad edge corrupts the
# whole rest of the line. Exactly one line per capture was coming out that way,
# reproducibly, on different lines each time.
#
# The real fix is synchronous capture (sampling ON DOTCLK rather than
# oversampling it), which is also what full-frame capture needs. Until then this
# filter is exact rather than approximate: it rejects only intervals that are
# physically impossible for the measured clock.
MIN_EDGE_SPACING = 4


def load_capture(path):
    d = json.load(open(path))
    return d["samples"], d.get("trig", 0)


def capture_live(port, mask, value, edge, post):
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    import serial
    from serial_selftest import find_port, drain
    from la_capture import Analyzer
    with serial.Serial(port or find_port(), 1_000_000, timeout=3) as ser:
        drain(ser)
        la = Analyzer(ser)
        la.reset()
        drain(ser, quiet_for=0.1, limit=1.0)
        la.set_source(mock=False)
        la.set_trigger(mask, value, edge)
        la.set_post(post)
        la.arm()
        st = la.wait_full(10.0)
        if not st.full:
            raise RuntimeError(f"capture did not complete ({st})")
        st, samples = la.fetch_all()
    return samples, st.trig


def decode(samples):
    """Return (lines, stats). Each line is a list of (c0, c1, c2) tuples."""
    n = len(samples)
    ck = [x & 1 for x in samples]
    de = [(x >> C_DE) & 1 for x in samples]
    dat = [(x >> 4) & 0xFF for x in samples]

    raw_rise = [i for i in range(1, n) if ck[i] and not ck[i - 1]]
    rise, rejected = [], 0
    for e in raw_rise:
        if rise and e - rise[-1] < MIN_EDGE_SPACING:
            rejected += 1
            continue
        rise.append(e)

    # Complete DE runs only. A run clipped by the start or end of the capture
    # has an arbitrary number of DOTCLKs in it, so its triplet grouping is
    # meaningless -- including it produces a line of convincing garbage.
    runs, start = [], None
    for i in range(1, n):
        if de[i] and not de[i - 1]:
            start = i
        elif not de[i] and de[i - 1] and start is not None:
            runs.append((start, i))
            start = None

    lines, stats = [], []
    decode.rejected = rejected
    decode.raw_edges = len(raw_rise)
    for a, b in runs:
        ticks = [r for r in rise if a <= r < b]
        vals = [dat[min(r + SAMPLE_OFFSET, n - 1)] for r in ticks]
        px = [tuple(vals[i:i + 3]) for i in range(0, len(vals) - 2, 3)]
        mixed = sum(1 for p in px if not p[0] == p[1] == p[2])
        stats.append({"dotclks": len(ticks), "pixels": len(px), "mixed": mixed})
        lines.append(px)
    return lines, stats


def write_ppm(path, lines):
    """Binary PPM (P6). Deliberately dependency-free -- no Pillow needed."""
    w = max(len(l) for l in lines)
    h = len(lines)
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        for line in lines:
            row = bytearray()
            for i in range(w):
                p = line[i] if i < len(line) else (0, 0, 0)
                row += bytes(p)
            f.write(row)
    return w, h


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--capture", help="decode a saved JSON capture")
    src.add_argument("--live", action="store_true", help="capture from the board now")
    ap.add_argument("--port", default=None)
    ap.add_argument("--post", type=int, default=32767)
    ap.add_argument("--trigger", default="002:000",
                    help="hex MASK:VALUE; default 002:000 = HSYNC falling")
    ap.add_argument("--edge", action="store_true", default=True)
    ap.add_argument("--ppm", default=None, help="write the decoded lines to a PPM")
    ap.add_argument("--save", default=None, help="save the raw capture as JSON")
    ap.add_argument("--runs", action="store_true", help="print run-length structure per line")
    args = ap.parse_args()

    if args.live:
        mask, _, value = args.trigger.partition(":")
        samples, trig = capture_live(args.port, int(mask, 16), int(value, 16),
                                     args.edge, args.post)
        if args.save:
            json.dump({"count": len(samples), "trig": trig, "samples": samples},
                      open(args.save, "w"))
            print(f"INFO: saved raw capture to {args.save}")
    else:
        samples, trig = load_capture(args.capture)

    lines, stats = decode(samples)
    if not lines:
        print("FAIL: no complete DE run in the capture -- nothing to decode")
        return 1

    print(f"INFO: {len(samples)} samples, {len(lines)} complete line(s)")
    if decode.rejected:
        print(f"INFO: rejected {decode.rejected} of {decode.raw_edges} DOTCLK edges as "
              f"runts (< {MIN_EDGE_SPACING} samples apart) -- metastability from "
              f"oversampling an async clock only 8.1x")
    # Correctness is 960 DOTCLKs -> 320 pixels, and nothing else.
    #
    # An earlier version also required R == G == B on every pixel and called
    # anything else an error. That was over-fitting to the sample data: every
    # capture up to that point happened to be of a greyscale screen, so
    # "greyscale" got mistaken for "correct". The first genuinely coloured
    # capture -- a red screen, 320 px of ff 00 00 -- was then reported as 320
    # errors per line. The count is still shown because it IS informative (on
    # known-greyscale content a nonzero value means the sampling point or the
    # triplet phase is wrong) but it cannot be a pass criterion.
    for i, st in enumerate(stats):
        flag = ""
        if st["pixels"] != ACTIVE_PIXELS:
            flag += f"  <- expected {ACTIVE_PIXELS} pixels"
        if st["dotclks"] != ACTIVE_PIXELS * BYTES_PER_PIXEL:
            flag += f"  <- expected {ACTIVE_PIXELS * BYTES_PER_PIXEL} DOTCLKs"
        kind = "greyscale" if st["mixed"] == 0 else f"{st['mixed']} coloured px"
        print(f"  line {i}: {st['dotclks']:4d} DOTCLKs -> {st['pixels']:3d} px  "
              f"[{kind}]{flag}")

    if args.runs:
        for i, line in enumerate(lines):
            rl, cur, c = [], line[0], 0
            for p in line:
                if p == cur:
                    c += 1
                else:
                    rl.append((cur, c)); cur = p; c = 1
            rl.append((cur, c))
            print(f"\n  line {i}: {len(rl)} runs")
            for p, c in rl:
                print(f"    {c:4d} px  {p[0]:02x} {p[1]:02x} {p[2]:02x}")

    if args.ppm:
        w, h = write_ppm(args.ppm, lines)
        print(f"INFO: wrote {args.ppm} ({w}x{h})")

    good = sum(1 for st in stats
               if st["pixels"] == ACTIVE_PIXELS
               and st["dotclks"] == ACTIVE_PIXELS * BYTES_PER_PIXEL)
    if good != len(lines):
        print(f"FAIL: {len(lines) - good} of {len(lines)} line(s) did not decode to "
              f"{ACTIVE_PIXELS} pixels from {ACTIVE_PIXELS * BYTES_PER_PIXEL} DOTCLKs")
        return 1
    print(f"PASS: decoded {good}/{len(lines)} line(s) to {ACTIVE_PIXELS} pixels "
          f"({BYTES_PER_PIXEL} DOTCLKs each, R G B), 0 errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
