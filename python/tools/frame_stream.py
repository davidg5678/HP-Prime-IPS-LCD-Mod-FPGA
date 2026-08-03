#!/usr/bin/env python3
"""
Live view of the HP Prime's screen.

Starts the frame_stream bitstream and decodes its continuous RLE byte stream,
writing each frame out as a PPM (and optionally reporting rate). About 2 frames
per second at 1 Mbaud -- see docs/streaming.md for why that number is what it
is and why a faster link does not help.

WIRE FORMAT (self-framing: an RLE count is never zero)
    00 01          start of frame
    00 02          the previous frame was truncated
    00 00          padding, skip
    NN RR GG BB    a run of NN pixels of colour RR,GG,BB   (NN = 1..255)
Runs may span line ends; the host fills a linear buffer and wraps at WIDTH.
"""
import argparse
import sys
import time

import serial

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from serial_selftest import find_port, drain  # noqa: E402

BAUD = 1_000_000
CMD_STOP, CMD_RUN, CMD_STATUS = 0xAA, 0x52, 0x53
HDR_MAGIC, HDR_VERSION = 0xA5, 0x05
WIDTH, HEIGHT = 320, 240


def write_ppm(path, px, w, h):
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        body = bytearray()
        for i in range(w * h):
            body += bytes(px[i]) if i < len(px) else b"\0\0\0"
        f.write(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--frames", type=int, default=5, help="frames to capture (0 = forever)")
    ap.add_argument("--ppm", default=None,
                    help="write frames here; %%d in the name numbers them")
    ap.add_argument("--timeout", type=float, default=30.0)
    args = ap.parse_args()

    with serial.Serial(args.port or find_port(), BAUD, timeout=2) as ser:
        stale = drain(ser)
        if stale:
            print(f"INFO: discarded {stale} bytes of pre-existing traffic")
        ser.write(bytes([CMD_STOP])); ser.flush()
        time.sleep(0.05)
        drain(ser, quiet_for=0.1, limit=1.0)

        ser.write(bytes([CMD_STATUS])); ser.flush()
        rep = ser.read(8)
        if len(rep) != 8 or rep[0] != HDR_MAGIC or rep[1] != HDR_VERSION:
            print(f"FAIL: bad status reply {rep.hex() if rep else '(none)'}")
            return 1
        if not (rep[2] & 0x01) or not (rep[2] & 0x02):
            print(f"FAIL: not ready (pll={bool(rep[2]&1)} sdram={bool(rep[2]&2)})")
            return 1
        print("INFO: PLL locked, SDRAM initialised; starting stream")

        ser.write(bytes([CMD_RUN])); ser.flush()

        # Indexed, never sliced from the front. An earlier version did
        # `del buf[:4]` per run, which is O(n) on a bytearray and therefore
        # O(n^2) per frame -- with ~12,000 runs the decoder fell behind, the OS
        # serial buffer overflowed, and frames after the first came out short.
        # The FPGA was not at fault.
        buf = bytearray()
        pos = 0
        px, frames, truncated = [], 0, 0
        t_start = time.time()
        state = "sync"          # sync -> collecting
        deadline = t_start + args.timeout

        def need(n):
            nonlocal buf, pos
            while len(buf) - pos < n:
                if pos > 65536:                 # compact occasionally, not per run
                    del buf[:pos]
                    pos = 0
                c = ser.read(8192)
                if not c:
                    return False
                buf += c
            return True

        while (args.frames == 0 or frames < args.frames) and time.time() < deadline:
            if not need(2):
                break
            if buf[pos] == 0x00:
                # Padding zeros are skipped ONE AT A TIME. The encoder pads its
                # final word with 1-3 zero bytes, so consuming them in pairs
                # makes an odd pad byte swallow the next frame marker's 0x00 --
                # leaving its 0x01 to be read as a run count, and everything
                # after that decodes as garbage.
                if buf[pos + 1] not in (0x01, 0x02):
                    pos += 1
                    continue
                marker = buf[pos + 1]
                pos += 2
                if marker in (0x01, 0x02):
                    if state == "collecting":
                        frames += 1
                        if marker == 0x02:
                            truncated += 1
                        got = len(px)
                        rate = frames / (time.time() - t_start)
                        print(f"  frame {frames}: {got:,} px "
                              f"({100.0*got/(WIDTH*HEIGHT):5.1f}% of {WIDTH}x{HEIGHT})"
                              f"{'  TRUNCATED' if marker == 0x02 else ''}"
                              f"   {rate:.2f} fps")
                        if args.ppm:
                            name = (args.ppm % frames) if "%" in args.ppm else args.ppm
                            write_ppm(name, px, WIDTH, HEIGHT)
                    px = []
                    state = "collecting"
                    deadline = time.time() + args.timeout
                continue
            if not need(4):
                break
            n, r, g, b = buf[pos], buf[pos+1], buf[pos+2], buf[pos+3]
            pos += 4
            if state == "collecting":
                px.extend([(r, g, b)] * n)

        ser.write(bytes([CMD_STOP])); ser.flush()
        time.sleep(0.05)
        drain(ser, quiet_for=0.1, limit=1.0)

    if frames == 0:
        print("FAIL: no complete frames received")
        return 1
    elapsed = time.time() - t_start
    print(f"INFO: {frames} frames in {elapsed:.1f}s = {frames/elapsed:.2f} fps"
          f"{f', {truncated} truncated' if truncated else ''}")
    if truncated:
        print(f"FAIL: {truncated} of {frames} frames were truncated by the encoder")
        return 1
    print(f"PASS: live stream, {frames} frames decoded at {frames/elapsed:.2f} fps, 0 truncated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
