#!/usr/bin/env python3
"""
Host driver for the Phase 3 panel target (src/targets/lcd_panel).

Verifies that the FPGA is emitting panel-legal RGB timing, and drives the test
patterns and the backlight. Follows this repo's PASS:/FAIL: + exit-code
contract.

WHAT THIS CAN AND CANNOT TELL YOU
---------------------------------
It reads the timing the FPGA MEASURED OFF ITS OWN OUTPUT PINS -- DCLKs per
line, active DCLKs per line, lines per frame, active lines per frame -- and
compares them against the AFY320240A0 datasheet's typical column. That is a
real end-to-end check of the whole output path: the monitor in lcd_panel_top
counts edges on lcd_ck/lcd_hs/lcd_vs/lcd_de after they leave the timing
generator, so a broken DE gate or a stalled counter shows up here.

It CANNOT tell you the panel is displaying anything. Nothing on the 40-pin
connector comes back to the FPGA; the panel's SPI is unreachable because the
board grounds its CS pin, and its touch controller is on a separate FFC this
connector does not carry. So a PASS means "the FPGA is driving correct video at
the connector", and the remaining question -- is the FFC seated, is it the
right contact orientation, is the backlight current sane -- is answered by
looking at the panel. --pattern exists to make that look diagnostic rather than
merely hopeful; see the pattern table below.

FIRST LIGHT, in order:
    make build BUILD_TARGET=lcd_panel
    make flash-sram BUILD_TARGET=lcd_panel
    make lcd-hw                        # timing check, pattern 0 (GRID)
    make lcd-hw PATTERN=1              # colour bars -- check channel wiring
    make lcd-hw PATTERN=2              # ramps -- check bit order within a channel
    make lcd-hw PATTERN=4 BL=200       # white, brighter -- MEASURE THE CURRENT

BACKLIGHT, read this before turning it up
-----------------------------------------
The panel wants 19.2 V at 40 mA and its absolute maximum is 50 mA. The board's
boost driver (U6, sense resistor R31 = 5.6 ohm) was designed for Sipeed's own
4.3" panel, not this one. The bitstream comes up at 25% PWM duty deliberately.
Measure the LED current before running at a high duty continuously --
over-driving shortens LED life and the datasheet says so explicitly.
"""
import argparse
import sys
import time

import serial

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from serial_selftest import find_port, drain  # noqa: E402

BAUD = 1_000_000
CMD_RESET, CMD_PATTERN, CMD_BL, CMD_STATUS = 0xAA, 0x50, 0x42, 0x53
CMD_LEDS = 0x4C
HDR_MAGIC, HDR_VERSION, HDR_LEN = 0xA5, 0x05, 16

# docs/AFY320240A0-3.5INTH-C2-spec.pdf p.10, typical column.
EXP_H_TOTAL, EXP_H_ACTIVE = 371, 320
EXP_V_TOTAL, EXP_V_ACTIVE = 260, 240
DCLK_HZ = 6_000_000

PATTERNS = {
    0: ("GRID",    "1-px border + 32-px grid + centre crosshair -- GEOMETRY. "
                   "A missing right or bottom border line means DE is short."),
    1: ("BARS",    "8 colour bars, 40 px each -- CHANNEL WIRING. "
                   "Order is white, yellow, cyan, green, magenta, red, blue, black."),
    2: ("RAMPS",   "per-channel 256-px ramps in three bands -- BIT ORDER. "
                   "A swapped bit in one channel makes its ramp jump backwards."),
    3: ("PLAID",   "R=x, G=y, B=x^y -- the same image Phase 1's mock feeds the "
                   "capture path, so Phase 4 can compare the two."),
    4: ("WHITE",   "backlight uniformity -- MEASURE THE LED CURRENT ON THIS ONE."),
    5: ("BLACK",   "contrast floor."),
    6: ("THIRDS",  "solid red / green / blue bands, readable across a room."),
    7: ("CHECKER", "1-px checkerboard -- SIGNAL INTEGRITY. Every data line "
                   "toggles at 3 MHz; smearing here but nowhere else points at "
                   "DCLK phase or FFC length."),
}


class Report:
    def __init__(self, raw):
        self.magic, self.version = raw[0], raw[1]
        s = raw[2]
        self.pll_lock = bool(s & 0x01)
        self.bl_on    = bool(s & 0x02)
        self.running  = bool(s & 0x04)
        self.pattern  = raw[3] & 0x07
        self.bl_duty  = raw[4]
        self.h_total  = int.from_bytes(raw[6:8],   "little")
        self.h_active = int.from_bytes(raw[8:10],  "little")
        self.v_total  = int.from_bytes(raw[10:12], "little")
        self.v_active = int.from_bytes(raw[12:14], "little")
        self.frames   = int.from_bytes(raw[14:16], "little")
        self.raw = s

    def __str__(self):
        f = "".join(c for c, b in zip("LBR",
                    [self.pll_lock, self.bl_on, self.running]) if b)
        return (f"status=0x{self.raw:02x} [{f or '-'}] "
                f"pattern={self.pattern} bl_duty={self.bl_duty} "
                f"h={self.h_active}/{self.h_total} v={self.v_active}/{self.v_total} "
                f"frames={self.frames}")


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
    ap.add_argument("--pattern", type=int, default=None, choices=sorted(PATTERNS),
                    help="test pattern to display (default: leave as-is)")
    ap.add_argument("--backlight", type=int, default=None, metavar="0-255",
                    help="backlight PWM duty; 0 is off, 64 is the power-on default")
    ap.add_argument("--leds", choices=("on", "off"), default=None,
                    help="the six-LED status row. Default at power-on is off; "
                         "leds[0] always keeps a ~1.6 Hz heartbeat so the board "
                         "can still be told apart from an unconfigured one.")
    args = ap.parse_args()

    if args.backlight is not None and not 0 <= args.backlight <= 255:
        print("FAIL: --backlight must be 0..255")
        return 1

    with serial.Serial(args.port or find_port(), BAUD, timeout=3) as ser:
        stale = drain(ser)
        if stale:
            print(f"INFO: discarded {stale} bytes of pre-existing traffic")

        try:
            if args.pattern is not None:
                ser.write(bytes([CMD_PATTERN, args.pattern]))
                ser.flush()
            if args.backlight is not None:
                ser.write(bytes([CMD_BL, args.backlight]))
                ser.flush()
            if args.leds is not None:
                ser.write(bytes([CMD_LEDS, 1 if args.leds == "on" else 0]))
                ser.flush()
            if any(a is not None for a in (args.pattern, args.backlight, args.leds)):
                time.sleep(0.05)

            r = status(ser)
            # A second read a known interval later gives the frame RATE, which
            # the FPGA does not report and which is the one figure that proves
            # the timing generator is running at the speed it thinks it is
            # rather than merely producing correctly-shaped frames.
            f0, t0 = r.frames, time.time()
            time.sleep(0.5)
            r = status(ser)
            elapsed = time.time() - t0
            # The counter is 16 bits and rolls over every ~17 minutes at 62 Hz.
            dframes = (r.frames - f0) & 0xFFFF
            fps = dframes / elapsed
        except (TimeoutError, ValueError) as e:
            print(f"FAIL: {e}")
            return 1

    print(f"INFO: {r}")
    name, hint = PATTERNS[r.pattern]
    print(f"INFO: pattern {r.pattern} = {name} -- {hint}")

    if not r.pll_lock:
        print(f"FAIL: PLL not locked ({r})")
        return 1
    if not r.running:
        print("FAIL: no frames emitted -- the timing generator is not running")
        return 1

    bad = []
    for what, got, exp in (
        ("DCLKs per line",         r.h_total,  EXP_H_TOTAL),
        ("active DCLKs per line",  r.h_active, EXP_H_ACTIVE),
        ("lines per frame",        r.v_total,  EXP_V_TOTAL),
        ("active lines per frame", r.v_active, EXP_V_ACTIVE),
    ):
        if got != exp:
            bad.append(f"{what} = {got}, expected {exp}")
    if bad:
        for b in bad:
            print(f"FAIL: {b}")
        return 1

    # Derived, and cross-checked against the datasheet's own ranges rather than
    # against the constants above -- the same two-instruments-agreeing argument
    # docs/prime_lcd_protocol.md makes for the Prime's frame rate.
    line_us = r.h_total / DCLK_HZ * 1e6
    frame_hz = DCLK_HZ / (r.h_total * r.v_total)
    print(f"INFO: line {line_us:.1f} us (spec 55-65), "
          f"frame {frame_hz:.1f} Hz (spec ~58-68), "
          f"measured {fps:.1f} fps over {elapsed:.2f}s")

    if not 55.0 <= line_us <= 65.0:
        print(f"FAIL: line period {line_us:.1f} us is outside the panel's 55-65 us spec")
        return 1
    if not 58.0 <= frame_hz <= 68.0:
        print(f"FAIL: frame rate {frame_hz:.1f} Hz is outside the panel's ~58-68 Hz spec")
        return 1
    # Generous bound: this is wall-clock over USB serial, not an instrument.
    if abs(fps - frame_hz) > 5.0:
        print(f"FAIL: measured {fps:.1f} fps but the timing implies {frame_hz:.1f} Hz "
              "-- frames are being emitted at the wrong rate")
        return 1

    if not r.bl_on:
        print("INFO: backlight is off (duty 0, or the 250 ms T2 delay has not "
              "elapsed since reset)")

    print(f"PASS: lcd_panel emitting {r.h_active}x{r.v_active} in "
          f"{r.h_total}x{r.v_total} at {frame_hz:.1f} Hz, "
          f"pattern {r.pattern} ({name}), backlight duty {r.bl_duty}/255")
    return 0


if __name__ == "__main__":
    sys.exit(main())
