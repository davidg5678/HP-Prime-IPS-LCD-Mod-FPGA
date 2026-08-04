#!/usr/bin/env python3
"""
Host tool for the Phase 4 passthrough target (src/targets/passthrough).

THIS TOOL CARRIES NO PIXELS, AND THAT IS THE POINT
--------------------------------------------------
Phase 4's video path is HP Prime -> SDRAM -> panel, entirely inside the FPGA.
The host is not in it. Phase 2's frame streaming over the UART topped out at
2.0-2.6 fps even after 4.6x RLE compression, because the ceiling was per-request
latency rather than bit rate (raising the baud rate made it WORSE -- see
PROGRESS.md 2026-08-03 part 3). The internal path is 108 MHz x 32 bits =
432 MB/s, about 4000x the serial link. So streaming was abandoned deliberately,
not left unfinished, and this tool does not do it.

What it does is send single command bytes and read a 24-byte status report --
a few bytes per second, on demand. Control and telemetry only.

YOU DO NOT NEED THIS TOOL TO USE THE PASSTHROUGH
------------------------------------------------
The bitstream powers up in AUTO: it shows the mock test pattern until a complete
captured frame has been swapped in, then switches to the live passthrough on its
own and stays there. Calculator in, panel out, no computer. Flash it with
`make flash BUILD_TARGET=passthrough` and it survives power cycles.

This tool exists for when that DOESN'T happen, because the report distinguishes
faults that all look identical on the glass:

    panel shows the GRID pattern    -> FPGA, FFC and output path are all fine;
                                       the calculator is not driving. Check
                                       src_frames -- if it is 0, check probes.
    panel is black                  -> backlight (see below), or no bitstream
    panel shows a wrong-looking     -> force MOCK and see whether the pattern is
      image                            also wrong. That separates panel faults
                                       from capture faults in one command.

THE BACKLIGHT IS OFF AT POWER-ON, DELIBERATELY. Use --backlight 255.
Intermediate values DO NOT WORK on this board: the pin drives the LP3320's
ENABLE, and at ~1 kHz PWM a 25% duty gives a 250 us on-time that never clears
the converter's soft-start -- the panel stays dark while the report says the
backlight is on. Measured from both directions in PROGRESS.md 2026-08-04.
The panel wants 19.2 V at 40 mA, absolute max 50 mA; measure before leaving it
on continuously.

FIRST LIGHT, in order -- one variable at a time, per docs/verification.md:

    make build BUILD_TARGET=passthrough
    make flash-sram BUILD_TARGET=passthrough
    make pass-hw MODE=mock BL=255     # panel only, no probes: is Phase 3 intact
                                      # inside the bigger bitstream?
    make pass-hw                      # attach probes, still forced MOCK if you
                                      # like: watch src_frames climb, and check
                                      # src_lines=240 / src_px_line=320. This
                                      # answers "is the calculator driving?"
                                      # WITHOUT disturbing the panel.
    make pass-hw MODE=auto            # hand control back; it should go live.

Exit code and PASS:/FAIL: line follow this repo's contract (see CLAUDE.md).
"""
import argparse
import sys
import time

import serial

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from serial_selftest import find_port, drain  # noqa: E402

BAUD = 1_000_000

CMD_RESET, CMD_AUTO, CMD_MOCK = 0xAA, 0x41, 0x4D
CMD_REAL, CMD_PATTERN, CMD_BL, CMD_STATUS = 0x52, 0x50, 0x42, 0x53

HDR_MAGIC, HDR_VERSION, HDR_LEN = 0xA5, 0x07, 24

MODE_AUTO, MODE_MOCK, MODE_REAL = 0, 1, 2
MODE_NAMES = {MODE_AUTO: "AUTO", MODE_MOCK: "MOCK", MODE_REAL: "REAL"}
MODE_BYTES = {"auto": CMD_AUTO, "mock": CMD_MOCK, "real": CMD_REAL}

# docs/AFY320240A0-3.5INTH-C2-spec.pdf p.10, typical column.
EXP_H_TOTAL, EXP_H_ACTIVE = 371, 320
EXP_V_TOTAL, EXP_V_ACTIVE = 260, 240
DCLK_HZ = 6_000_000

# docs/prime_lcd_protocol.md -- measured on the calculator, not assumed.
EXP_SRC_LINES, EXP_SRC_PX = 240, 320

PATTERNS = ["GRID", "BARS", "RAMPS", "PLAID", "WHITE", "BLACK", "THIRDS",
            "CHECKER"]


class Report:
    """The 24-byte status report, decoded. Field names match the RTL's comment
    block in src/targets/passthrough/passthrough_top.v."""

    def __init__(self, raw: bytes):
        self.raw = raw
        self.magic = raw[0]
        self.version = raw[1]
        st = raw[2]
        self.pll_lock = bool(st & 0x01)
        self.sdram_init = bool(st & 0x02)
        self.effective_real = bool(st & 0x04)
        self.backlight_on = bool(st & 0x08)
        self.panel_running = bool(st & 0x10)
        self.wr_overrun = bool(st & 0x20)
        self.rd_underrun = bool(st & 0x40)
        self.pattern = raw[3] & 0x07
        self.bl_duty = raw[4]
        self.mode_sel = raw[5] & 0x03
        self.have_frame = bool(raw[5] & 0x04)

        def u16(i):
            return raw[i] | (raw[i + 1] << 8)

        self.h_total = u16(6)
        self.h_active = u16(8)
        self.v_total = u16(10)
        self.v_active = u16(12)
        self.frames = u16(14)
        self.src_frames = u16(16)
        self.src_lines = u16(18)
        self.src_px_line = u16(20)
        self.runts = u16(22)

    @property
    def line_us(self):
        return self.h_total * 1e6 / DCLK_HZ

    @property
    def frame_hz(self):
        if not (self.h_total and self.v_total):
            return 0.0
        return DCLK_HZ / (self.h_total * self.v_total)


def read_report(port) -> Report:
    port.reset_input_buffer()
    port.write(bytes([CMD_STATUS]))
    port.flush()
    raw = port.read(HDR_LEN)
    if len(raw) != HDR_LEN:
        # Dump what did arrive rather than theorising. A short reply with
        # version 0x02 in 10 bytes means the board reset and reconfigured from
        # flash (which still holds la_capture) -- a free diagnostic that costs
        # nothing to print and has been mistaken for a dead link before.
        raise IOError(
            f"short report: {len(raw)}/{HDR_LEN} bytes: {raw.hex(' ') or '(none)'}\n"
            "  A 10-byte reply starting a5 02 means the board reset and is now\n"
            "  running la_capture from flash. Re-flash the passthrough bitstream."
        )
    return Report(raw)


def describe(r: Report) -> None:
    print(f"  protocol version    0x{r.version:02x}")
    print(f"  pll lock            {r.pll_lock}")
    print(f"  sdram initialised   {r.sdram_init}")
    print(f"  panel running       {r.panel_running}")
    print(f"  requested mode      {MODE_NAMES.get(r.mode_sel, r.mode_sel)}")
    print(f"  effective mode      {'REAL' if r.effective_real else 'MOCK'}"
          f"   (have_frame={r.have_frame})")
    print(f"  mock pattern        {r.pattern} "
          f"({PATTERNS[r.pattern] if r.pattern < len(PATTERNS) else '?'})")
    print(f"  backlight           duty {r.bl_duty}, on={r.backlight_on}")
    print()
    print("  --- panel, measured by the FPGA off its own output pins ---")
    print(f"  DCLKs per line      {r.h_total} (expect {EXP_H_TOTAL})")
    print(f"  active DCLKs        {r.h_active} (expect {EXP_H_ACTIVE})")
    print(f"  lines per frame     {r.v_total} (expect {EXP_V_TOTAL})")
    print(f"  active lines        {r.v_active} (expect {EXP_V_ACTIVE})")
    print(f"  line period         {r.line_us:.2f} us (spec 55-65)")
    print(f"  frame rate          {r.frame_hz:.2f} Hz (spec ~58-68)")
    print(f"  panel frames        {r.frames}")
    print()
    print("  --- source, captured from the HP Prime ---")
    print(f"  source frames       {r.src_frames}")
    print(f"  lines in last frame {r.src_lines} (expect {EXP_SRC_LINES})")
    print(f"  pixels in last line {r.src_px_line} (expect {EXP_SRC_PX})")
    print(f"  runt DOTCLK edges   {r.runts}")
    print(f"  writer overrun      {r.wr_overrun}")
    print(f"  reader underrun     {r.rd_underrun}")


def main():
    ap = argparse.ArgumentParser(
        description="Control and telemetry for the Phase 4 passthrough. "
                    "Carries no pixels; the video path is internal.")
    ap.add_argument("--port")
    ap.add_argument("--mode", choices=["auto", "mock", "real"],
                    help="force the pixel source. Omit to leave it alone. "
                         "'auto' restores the power-on behaviour.")
    ap.add_argument("--pattern", type=int, choices=range(8),
                    help="mock pattern index: " +
                         ", ".join(f"{i} {n}" for i, n in enumerate(PATTERNS)))
    ap.add_argument("--backlight", type=int, metavar="0..255",
                    help="backlight duty. USE 255 -- intermediate values do not "
                         "work on this board (LP3320 soft-start). Measure the "
                         "LED current before leaving it on.")
    ap.add_argument("--reset", action="store_true",
                    help="send CMD_RESET: restart capture, buffers and the "
                         "panel timing generator, and return the mux to AUTO")
    ap.add_argument("--watch", type=float, metavar="SECONDS",
                    help="poll the report for this long and report progress")
    args = ap.parse_args()

    if args.backlight is not None and not 0 <= args.backlight <= 255:
        print("FAIL: --backlight must be 0..255")
        return 1

    port_name = args.port or find_port()
    if not port_name:
        print("FAIL: no serial port found")
        return 1

    with serial.Serial(port_name, BAUD, timeout=1.0) as port:
        drain(port)

        if args.reset:
            port.write(bytes([CMD_RESET]))
            port.flush()
            time.sleep(0.05)
        if args.mode:
            port.write(bytes([MODE_BYTES[args.mode]]))
            port.flush()
            time.sleep(0.05)
        if args.pattern is not None:
            port.write(bytes([CMD_PATTERN, args.pattern]))
            port.flush()
            time.sleep(0.05)
        if args.backlight is not None:
            port.write(bytes([CMD_BL, args.backlight]))
            port.flush()
            time.sleep(0.05)

        # Let the mux settle: it is latched at the panel's frame boundary, so a
        # command needs up to two 16 ms frames to be visible in the report.
        if args.mode or args.reset:
            time.sleep(0.10)

        try:
            r = read_report(port)
        except IOError as e:
            print(f"FAIL: {e}")
            return 1

        # ---- wall-clock cross-check. The FPGA's frame counter is derived from
        # edges it counted on its own pins; timing it against the host's clock
        # is an INDEPENDENT instrument. A mis-locked PLL or a miscounting phase
        # generator still produces self-consistent 371x260 frames -- only this
        # comparison catches that. Same two-instruments argument
        # docs/prime_lcd_protocol.md uses for the Prime's frame rate.
        t0, f0, s0 = time.time(), r.frames, r.src_frames
        time.sleep(args.watch if args.watch else 0.5)
        r2 = read_report(port)
        dt = time.time() - t0
        panel_fps = ((r2.frames - f0) & 0xFFFF) / dt
        src_fps = ((r2.src_frames - s0) & 0xFFFF) / dt

    print(f"port {port_name}")
    print()
    describe(r2)
    print()
    print(f"  measured over {dt:.2f} s of host wall-clock:")
    print(f"  panel  {panel_fps:.1f} fps (expect ~62)")
    print(f"  source {src_fps:.1f} fps (expect ~37.7 if the Prime is driving)")

    # ---------------------------------------------------------------- verdict
    fails = []
    if r2.magic != HDR_MAGIC:
        fails.append(f"bad magic 0x{r2.magic:02x}")
    if r2.version != HDR_VERSION:
        fails.append(f"protocol version 0x{r2.version:02x}, expected "
                     f"0x{HDR_VERSION:02x} -- wrong bitstream flashed?")
    if not r2.pll_lock:
        fails.append("PLL not locked")
    if not r2.sdram_init:
        fails.append("SDRAM not initialised")
    if not r2.panel_running:
        fails.append("panel timing generator is not running")
    for name, got, exp in (("DCLKs per line", r2.h_total, EXP_H_TOTAL),
                           ("active DCLKs", r2.h_active, EXP_H_ACTIVE),
                           ("lines per frame", r2.v_total, EXP_V_TOTAL),
                           ("active lines", r2.v_active, EXP_V_ACTIVE)):
        if got != exp:
            fails.append(f"{name} = {got}, expected {exp}")
    if not 55.0 <= r2.line_us <= 65.0:
        fails.append(f"line period {r2.line_us:.2f} us outside the panel's 55-65")
    if panel_fps < 55.0:
        fails.append(f"panel only {panel_fps:.1f} fps against wall-clock")
    if r2.wr_overrun:
        fails.append("writer FIFO overran -- captured frames are corrupt")
    if r2.rd_underrun:
        fails.append("reader FIFO underran -- displayed pixels are wrong")

    if fails:
        print()
        print("FAIL: " + "; ".join(fails))
        return 1

    # The source side is REPORTED, never a pass criterion. The whole point of
    # running the capture path in both modes is to answer "is the calculator
    # connected?" separately from "is the FPGA driving the panel correctly?" --
    # and this tool must still pass on a bench with no calculator attached, or
    # it cannot be used to check the panel path on its own.
    if r2.src_frames == 0:
        note = "no source frames yet -- the calculator is not driving (panel " \
               "shows the mock pattern, which is the AUTO behaviour)"
    elif (r2.src_lines, r2.src_px_line) != (EXP_SRC_LINES, EXP_SRC_PX):
        note = (f"source geometry {r2.src_px_line}x{r2.src_lines}, expected "
                f"{EXP_SRC_PX}x{EXP_SRC_LINES} -- check the probe wiring")
    else:
        note = (f"source {EXP_SRC_PX}x{EXP_SRC_LINES} at {src_fps:.1f} fps, "
                f"{r2.runts} runt edges, "
                f"{'LIVE PASSTHROUGH' if r2.effective_real else 'mock pattern'} "
                f"on the panel")

    print()
    print(f"PASS: passthrough emitting {r2.h_active}x{r2.v_active} in "
          f"{r2.h_total}x{r2.v_total} at {r2.frame_hz:.1f} Hz "
          f"({panel_fps:.1f} fps wall-clock); {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
