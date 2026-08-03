#!/usr/bin/env python3
"""
Host-side driver for the Phase 1 logic analyser (src/targets/la_capture).

Arms a capture, waits for the trigger, drains the buffer over the onboard
BL616 UART, and either verifies the MOCK test pattern or writes the capture out
as a VCD for GTKWave / PulseView.

Follows this repo's PASS:/FAIL: + exit-code contract (see CLAUDE.md) so an
agent can drive it exactly like `make sim` and `make build`.

Examples
    python3 python/tools/la_capture.py                       # mock self-test
    python3 python/tools/la_capture.py --vcd captures/x.vcd  # self-test + VCD
    python3 python/tools/la_capture.py --real --trigger 004:000 --edge \\
            --post 24576 --vcd captures/prime.vcd
"""
import argparse
import sys
import time

import serial

# Reuse the port discovery and drain logic that proto-phase-1 already got right
# -- including the two BL616 gotchas (interface A echoes, interface B carries
# the programmer's own log). Duplicating them here would mean maintaining two
# copies of hard-won knowledge.
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from serial_selftest import find_port, drain  # noqa: E402

BAUD = 1_000_000

CMD_RESET, CMD_MOCK, CMD_REAL = 0xAA, 0x4D, 0x52
CMD_ARM, CMD_STATUS, CMD_DRAIN = 0x41, 0x53, 0x44
CMD_TRIG, CMD_POST = 0x54, 0x50
CMD_EDGE, CMD_LEVEL = 0x45, 0x4C
CMD_READ = 0x47

HDR_MAGIC, HDR_VERSION, HDR_LEN = 0xA5, 0x02, 10

# Samples per windowed read. 4096 samples = 8202 bytes, which comfortably fits
# any plausible driver buffer, so the FPGA is never transmitting into a full
# one. An unwindowed full drain (64 KB continuous, no flow control) was
# measured losing 263-1904 bytes at random on this hardware.
CHUNK = 4096

# Channel map -- must match the CHANNEL MAP comment in la_capture_top.v and the
# pin table in boards/tangnano20k/pinout.md. On the HP Prime's 45-pin LCD flex
# these are pins 10, 9, 8, 7 and 11..18 respectively.
CHANNELS = ["DOTCLK", "HSYNC", "VSYNC", "DE"] + [f"D{i}" for i in range(8)]
C_DOTCLK, C_HSYNC, C_VSYNC, C_DE = 0, 1, 2, 3

# Synthesis defaults of video_timing_gen, used to check the MOCK pattern.
DOTCLK_DIV, H_TOTAL, H_SYNC, H_START, H_ACTIVE = 8, 120, 6, 18, 96
V_TOTAL, V_SYNC, V_START, V_ACTIVE = 10, 1, 2, 8

SAMPLE_NS = 1000.0 / 108.0   # 108 MHz sample clock


class Status:
    def __init__(self, raw: bytes):
        self.magic, self.version, s = raw[0], raw[1], raw[2]
        self.running   = bool(s & 0x01)
        self.triggered = bool(s & 0x02)
        self.full      = bool(s & 0x04)
        self.wrapped   = bool(s & 0x08)
        self.mock      = bool(s & 0x10)
        self.pll_lock  = bool(s & 0x20)
        self.edge      = bool(s & 0x40)
        self.count = raw[4] | (raw[5] << 8)     # total samples in the capture
        self.trig  = raw[6] | (raw[7] << 8)
        self.reply = raw[8] | (raw[9] << 8)     # samples in THIS reply
        self.raw = s

    def __str__(self):
        flags = "".join(c for c, f in zip("RTFWMPE", [
            self.running, self.triggered, self.full, self.wrapped,
            self.mock, self.pll_lock, self.edge]) if f)
        return (f"status=0x{self.raw:02x} [{flags or '-'}] "
                f"count={self.count} trig={self.trig}")


class Analyzer:
    def __init__(self, ser):
        self.ser = ser

    def _cmd(self, *b):
        self.ser.write(bytes(b))
        self.ser.flush()

    def _read_exact(self, n, what):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.ser.read(n - len(buf))
            if not chunk:
                raise TimeoutError(f"timed out reading {what}: "
                                   f"got {len(buf)} of {n} bytes")
            buf += chunk
        return bytes(buf)

    def status(self) -> Status:
        self._cmd(CMD_STATUS)
        raw = self._read_exact(HDR_LEN, "status header")
        st = Status(raw)
        if st.magic != HDR_MAGIC or st.version != HDR_VERSION:
            raise ValueError(f"bad header magic/version: "
                             f"0x{st.magic:02x}/0x{st.version:02x} "
                             f"(expected 0x{HDR_MAGIC:02x}/0x{HDR_VERSION:02x})")
        return st

    def reset(self):
        self._cmd(CMD_RESET)

    def set_source(self, mock: bool):
        self._cmd(CMD_MOCK if mock else CMD_REAL)

    def set_trigger(self, mask: int, value: int, edge: bool):
        self._cmd(CMD_TRIG, mask & 0xFF, (mask >> 8) & 0xFF,
                  value & 0xFF, (value >> 8) & 0xFF)
        self._cmd(CMD_EDGE if edge else CMD_LEVEL)

    def set_post(self, n: int):
        self._cmd(CMD_POST, n & 0xFF, (n >> 8) & 0xFF)

    def arm(self):
        self._cmd(CMD_ARM)

    def wait_full(self, timeout_s=5.0) -> Status:
        deadline = time.time() + timeout_s
        st = self.status()
        while not st.full and time.time() < deadline:
            time.sleep(0.01)
            st = self.status()
        return st

    def read_window(self, start, count):
        """Read `count` samples starting `start` in from the oldest."""
        self._cmd(CMD_READ, start & 0xFF, (start >> 8) & 0xFF,
                  count & 0xFF, (count >> 8) & 0xFF)
        hdr = self._read_exact(HDR_LEN, "read header")
        st = Status(hdr)
        if st.magic != HDR_MAGIC or st.version != HDR_VERSION:
            raise ValueError(f"bad read header 0x{st.magic:02x}/0x{st.version:02x}")
        body = self._read_exact(st.reply * 2, f"{st.reply} samples at {start}")
        return st, [body[i] | (body[i + 1] << 8) for i in range(0, len(body), 2)]

    def fetch_all(self):
        """Retrieve the whole capture in bounded chunks.

        Windowed rather than a single 'D': the FPGA has no flow control, so a
        64 KB continuous drain outruns the host's driver buffer and loses bytes
        irrecoverably. Asking for CHUNK samples at a time means the device is
        only ever sending what this process has already committed to read.
        """
        st = self.status()
        total, got = st.count, []
        while len(got) < total:
            want = min(CHUNK, total - len(got))
            rst, chunk = self.read_window(len(got), want)
            if not chunk:
                raise ValueError(f"empty reply reading {want} samples at {len(got)}; "
                                 f"capture reports {total} total")
            got.extend(chunk)
        return st, got


# --------------------------------------------------------------- decoding
def decode_dotclks(samples):
    """Recover one bus value per DOTCLK, exactly as a receiver would: latch on
    the DOTCLK rising edge, because the source presents data on the falling
    edge."""
    out = []
    for i in range(1, len(samples)):
        if (samples[i] & 1) and not (samples[i - 1] & 1):
            out.append({
                "at":    i,
                "hsync": (samples[i] >> C_HSYNC) & 1,
                "vsync": (samples[i] >> C_VSYNC) & 1,
                "de":    (samples[i] >> C_DE) & 1,
                "data":  (samples[i] >> 4) & 0xFF,
            })
    return out


def check_mock_pattern(samples):
    """Verify a MOCK capture against video_timing_gen's documented behaviour.
    Returns a list of human-readable problems; empty means correct."""
    errs = []
    d = decode_dotclks(samples)
    if len(d) < H_TOTAL * 2:
        return [f"only {len(d)} DOTCLK edges in {len(samples)} samples, "
                f"expected at least {H_TOTAL * 2}"]

    gaps = {d[i]["at"] - d[i - 1]["at"] for i in range(1, len(d))}
    if gaps != {DOTCLK_DIV}:
        errs.append(f"DOTCLK period(s) {sorted(gaps)} samples, expected "
                    f"{{{DOTCLK_DIV}}} -- sample clock is not 108 MHz or the "
                    f"generator's divider is wrong")

    falls = [i for i in range(1, len(d)) if not d[i]["hsync"] and d[i - 1]["hsync"]]
    periods = {falls[i] - falls[i - 1] for i in range(1, len(falls))}
    if not falls:
        errs.append("no HSYNC falling edge in the capture")
    elif periods and periods != {H_TOTAL}:
        errs.append(f"HSYNC period(s) {sorted(periods)} DOTCLKs, expected {H_TOTAL}")

    # A capture starts and ends at an arbitrary point in the frame, so the
    # first and last DE runs are truncated by construction. Only runs with a
    # rising edge INSIDE the capture are complete: a run recorded from index 0
    # was already in progress when sampling began, and a run still open at the
    # end never got its falling edge. Checking those against H_ACTIVE reports a
    # property of where the capture happened to start, not of the design.
    runs, start = [], None
    for i, s in enumerate(d):
        if s["de"] and start is None:
            start = i
        elif not s["de"] and start is not None:
            if start > 0:
                runs.append((start, i - start))
            start = None
    if not runs:
        errs.append("no complete DE run in the capture")
    for at, length in runs:
        if length != H_ACTIVE:
            errs.append(f"DE run of {length} DOTCLKs at {at}, expected {H_ACTIVE}")
            continue
        y = d[at + 1]["data"]          # G component carries the row index
        for j in range(H_ACTIVE):
            x, comp = j // 3, j % 3
            want = (x & 0xFF) if comp == 0 else (y if comp == 1 else ((x ^ y) & 0xFF))
            got = d[at + j]["data"]
            if got != want:
                errs.append(f"pixel at DOTCLK {at + j} (x={x} comp={comp} y={y}): "
                            f"got 0x{got:02x} expected 0x{want:02x}")
                break
        if y >= V_ACTIVE:
            errs.append(f"decoded row {y} outside V_ACTIVE={V_ACTIVE}")
    return errs


def probe_report(samples):
    """Per-channel activity summary of a capture.

    The point of this is first-connection bring-up: with twelve fine wires
    soldered to a calculator's flex, the question is never "what does the bus
    say" before it is "is every wire actually on the pin I think it is". A
    channel's frequency identifies it on its own -- DOTCLK, HSYNC and DE are
    orders of magnitude apart -- so this turns a wiring check into one command.
    """
    n = len(samples)
    if n < 2:
        return ["capture too short to analyse"]
    window_us = n * SAMPLE_NS / 1000.0
    lines = [f"  window {window_us:.1f} us ({n} samples at {1000/SAMPLE_NS:.0f} MHz)",
             "  ch  name    transitions   est. freq   %high  narrowest pulse  note"]
    for bit, name in enumerate(CHANNELS):
        seq = [(s >> bit) & 1 for s in samples]
        trans = [i for i in range(1, n) if seq[i] != seq[i - 1]]
        high = sum(seq)
        pct = 100.0 * high / n
        if not trans:
            note = ("STATIC LOW - unconnected? (inputs are pulled down)"
                    if seq[0] == 0 else "static high")
            lines.append(f"  {bit:>2}  {name:<6} {0:>11}   {'-':>9}   {pct:5.1f}  "
                         f"{'-':>15}  {note}")
            continue
        # Two transitions make one period.
        freq_hz = (len(trans) / 2.0) / (n * SAMPLE_NS * 1e-9)
        widths = [trans[i] - trans[i - 1] for i in range(1, len(trans))]
        narrow = min(widths) * SAMPLE_NS if widths else 0.0
        note = ""
        if len(trans) < 4:
            note = "too few edges for a reliable rate"
        if narrow and narrow < 2 * SAMPLE_NS:
            note = (note + "; " if note else "") + "pulses at the sample limit - aliasing"
        lines.append(f"  {bit:>2}  {name:<6} {len(trans):>11}   "
                     f"{_hz(freq_hz):>9}   {pct:5.1f}  "
                     f"{narrow:>12.1f} ns  {note}")
    return lines


def _hz(f):
    if f >= 1e6:
        return f"{f/1e6:.2f} MHz"
    if f >= 1e3:
        return f"{f/1e3:.2f} kHz"
    return f"{f:.1f} Hz"


def write_vcd(path, samples, trig_index):
    """Write the capture as a VCD. Only emits a timestamp when something
    changed, so a 32768-sample capture of a slow bus stays small."""
    ids = [chr(ord("!") + i) for i in range(len(CHANNELS))]
    with open(path, "w") as f:
        f.write("$date capture from la_capture $end\n")
        f.write("$version HP_PRIME_LCD phase 1 $end\n")
        f.write("$timescale 1ns $end\n$scope module probe $end\n")
        for name, vid in zip(CHANNELS, ids):
            f.write(f"$var wire 1 {vid} {name} $end\n")
        # A marker track, so the trigger position is visible in the viewer
        # rather than something you count samples to find.
        f.write(f"$var wire 1 {chr(ord('!') + len(CHANNELS))} TRIGGER $end\n")
        f.write("$upscope $end\n$enddefinitions $end\n")

        prev = None
        for i, s in enumerate(samples):
            t = int(round(i * SAMPLE_NS))
            changes = []
            for bit, vid in enumerate(ids):
                v = (s >> bit) & 1
                if prev is None or ((prev >> bit) & 1) != v:
                    changes.append(f"{v}{vid}")
            trig_now = 1 if i == trig_index else 0
            trig_prev = 1 if (i - 1) == trig_index else 0
            if prev is None or trig_now != trig_prev:
                changes.append(f"{trig_now}{chr(ord('!') + len(CHANNELS))}")
            if changes:
                f.write(f"#{t}\n" + "\n".join(changes) + "\n")
            prev = s


def parse_hex_pair(s):
    mask, _, value = s.partition(":")
    if not value:
        raise argparse.ArgumentTypeError("expected MASK:VALUE, e.g. 004:000")
    return int(mask, 16), int(value, 16)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=BAUD)
    ap.add_argument("--real", action="store_true",
                    help="capture the physical probe pins instead of the mock source")
    ap.add_argument("--trigger", type=parse_hex_pair, default=(0x000, 0x000),
                    metavar="MASK:VALUE",
                    help="hex mask:value over the 12 channels; default 000:000 "
                         "matches everything, i.e. trigger immediately")
    ap.add_argument("--edge", action="store_true",
                    help="require a transition into the trigger condition rather "
                         "than firing if it already holds at arm time")
    ap.add_argument("--post", type=int, default=None,
                    help="post-trigger samples (default: the design's own 3/4 of DEPTH)")
    ap.add_argument("--vcd", default=None, help="write the capture to this VCD file")
    ap.add_argument("--probe-check", action="store_true",
                    help="print a per-channel activity summary -- use this first after "
                         "wiring, to confirm every probe is on the pin you think it is")
    ap.add_argument("--timeout", type=float, default=10.0,
                    help="seconds to wait for the capture to complete")
    args = ap.parse_args()

    port = args.port or find_port()
    # A 32768-sample drain is 65544 bytes; at 1 Mbaud that is ~0.66 s of
    # continuous transfer, so the per-read timeout has to allow for it.
    with serial.Serial(port, args.baud, timeout=3) as ser:
        stale = drain(ser)
        if stale:
            print(f"INFO: discarded {stale} bytes of pre-existing traffic "
                  "(BL616 programming log)")

        la = Analyzer(ser)
        try:
            la.reset()
            time.sleep(0.02)
            drain(ser, quiet_for=0.1, limit=1.0)

            st = la.status()
            if not st.pll_lock:
                print(f"FAIL: PLL not locked ({st})")
                return 1

            la.set_source(mock=not args.real)
            mask, value = args.trigger
            la.set_trigger(mask, value, args.edge)
            if args.post is not None:
                la.set_post(args.post)
            la.arm()

            st = la.wait_full(args.timeout)
            if not st.full:
                print(f"FAIL: capture did not complete within {args.timeout}s ({st})")
                return 1

            st, samples = la.fetch_all()
        except (TimeoutError, ValueError) as e:
            print(f"FAIL: {e}")
            return 1

    print(f"INFO: {st}")
    if len(samples) != st.count:
        print(f"FAIL: header promised {st.count} samples, got {len(samples)}")
        return 1

    # Check the device's own claim about where the trigger landed. Cheap, and
    # valid for every capture including a real one, where nothing else about
    # the data can be predicted: the sample at trig_index must satisfy the
    # condition, and in EDGE mode the one before it must not.
    mask, value = args.trigger
    if mask and st.triggered and st.trig < len(samples):
        if (samples[st.trig] & mask) != (value & mask):
            print(f"FAIL: sample at trig_index {st.trig} is 0x{samples[st.trig]:03x}, "
                  f"which does not satisfy mask 0x{mask:03x} == 0x{value:03x}")
            return 1
        if args.edge and st.trig > 0:
            if (samples[st.trig - 1] & mask) == (value & mask):
                print(f"FAIL: sample before trig_index already satisfied the condition "
                      f"(0x{samples[st.trig - 1]:03x}) -- EDGE trigger did not fire on a transition")
                return 1
        print(f"INFO: trigger verified at index {st.trig} "
              f"(0x{samples[st.trig]:03x} matches 0x{mask:03x}==0x{value:03x})")

    if args.vcd:
        write_vcd(args.vcd, samples, st.trig)
        print(f"INFO: wrote {args.vcd} ({len(samples)} samples, "
              f"{len(samples) * SAMPLE_NS / 1000.0:.1f} us, trigger at index {st.trig})")

    if args.probe_check:
        print("INFO: per-channel activity")
        for line in probe_report(samples):
            print(line)
        print("INFO: expected from the scope survey -- DOTCLK ~13.1 MHz, HSYNC ~9.61 kHz,")
        print("      DE ~9.8 kHz. VSYNC is 37.7 Hz (26.5 ms period), far longer than this")
        print("      window, so it is EXPECTED to read static here; that is not a fault.")

    if args.real:
        # Nothing to check the physical bus against -- that is the whole point
        # of capturing it. Report shape and let the operator look.
        edges = sum(1 for i in range(1, len(samples)) if samples[i] != samples[i - 1])
        print(f"PASS: real capture, {len(samples)} samples, {edges} transitions, "
              f"trigger at index {st.trig}")
        return 0

    errs = check_mock_pattern(samples)
    if errs:
        for e in errs[:10]:
            print(f"FAIL: {e}")
        return 1
    print(f"PASS: la_capture mock capture, {len(samples)} samples verified "
          f"(DOTCLK period, HSYNC period, DE width, RGB pattern), 0 errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
