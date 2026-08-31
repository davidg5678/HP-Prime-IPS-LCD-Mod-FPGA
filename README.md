# HP Prime LCD → IPS panel, on an FPGA

Disclaimer: If you'd like to learn more about this project in a form that wasn't written by AI, please take a look at my website here:

https://davidigreen.com/blog/reverse-engineering-the-hp-prime-lcd-and-replacing-it-with-an-ips-panel

The FPGA programming phase of the project represents an experiment in evaluating the maturity of agentic AI for FPGA development work. Please excuse the slop nature of the repo, as it was built extensively with the help of AI. I hope to rewrite this readme myself later (I'm a real human), but for now, let the LLM-generated text begin!

Reverse-engineering the HP Prime graphing calculator's internal LCD bus on a
**Sipeed Tang Nano 20K** (Gowin `GW2AR-LV18QN88C8/I7`), and using it to drive a modern
replacement panel — calculator in, IPS panel out, no computer in the loop.

**All four phases are complete and working on hardware.**

| Phase | What it does | Status |
|---|---|---|
| **1 — Logic analyzer** | Capture DOTCLK/HSYNC/VSYNC/DE + 8-bit RGB bus into block RAM, drain over UART | ✅ on hardware |
| **2 — Decode / render** | Turn captures into 320×240 images in Python; whole-frame capture via SDRAM | ✅ on hardware |
| **3 — Panel driver** | Generate panel-legal parallel-RGB timing and drive the physical LCD | ✅ on hardware |
| **4 — Live passthrough** | Prime → capture → SDRAM triple-buffer → panel, entirely inside the FPGA | ✅ on hardware |

The passthrough runs the calculator's **37.7 Hz** source into a **62.2 Hz** panel through a triple
buffer in SDRAM, reproducing every frame with no tearing. It worked on the first hardware attempt.
The calculator's bus is fully reverse-engineered and specified in
[`docs/prime_lcd_protocol.md`](docs/prime_lcd_protocol.md) — every figure measured, none assumed.

> ⚠️ **Before wiring anything to the calculator, read
> [Pinouts → Danger pins](#danger-pins-on-the-hp-prime-flex) below.** Several pins on the Prime's
> display flex carry 16.88 V / −8.3 V rails that will destroy the FPGA.

---

## Repository layout

```
src/common/          Reusable RTL (UART, PLL, SDRAM controller, capture engine, timing gen, …)
src/targets/<name>/   One synthesizable build: <name>_top.v, <name>.cst, <name>.sdc, files.txt
sim/targets/<name>/   One testbench per target, same manifest convention
tools/{setup,sim,build}/   All automation scripts (invoked via the Makefile)
python/tools/         Host-side control + telemetry + offline decode/render
arduino/              Arduino sketches (currently only the touchscreen probe)
boards/tangnano20k/pinout.md   Full, measured pin reference — the authoritative source
docs/                 Protocol spec, panel analysis, architecture, verification doctrine, datasheets
captures/             Logic-analyzer artifacts (gitignored, regenerable)
```

Build targets: `bringup_selftest`, `la_capture`, `sdram_selftest`, `frame_capture`,
`frame_stream`, `lcd_panel`, `passthrough`.

---

## Hardware

| Item | Notes |
|---|---|
| Sipeed Tang Nano 20K | Gowin `GW2AR-18C`. Onboard BL616 provides JTAG **and** UART over one USB-C — no external adapter |
| HP Prime calculator | Signal is tapped from its 45-pin display flex; needs a breakout / pigtail |
| Replacement panel | Orient Display **AFY320240A0-3.5INTH-C2**, 320×240, parallel RGB. Mates the board's 40-pin 0.5 mm FFC on 38 of 40 pins — see [`docs/panel_afy320240a0.md`](docs/panel_afy320240a0.md) |
| Reversing FFC | The panel's FFC and the board's connector are **opposite contact types (A ↔ B)**. A same-type cable lands the panel's VDD / GND / 19 V backlight rail on FPGA I/O pads. Use a type-A↔B 40-pin 0.5 mm FFC or a breakout |
| Logic-level check | Confirm the Prime's DOTCLK swings to ≥ 2.0 V before connecting. If it is a 1.8 V domain, a level shifter is required |

No board is needed for `make sim`, `make build`, or `make build-oss` — only the `flash*` and
`*-hw` targets touch hardware.

---

## Getting started

### 1. Install the toolchain (macOS / Apple Silicon)

```bash
tools/setup/install_tools.sh
```

This installs via Homebrew: `icarus-verilog` (binary: `iverilog`), `verilator`, `openfpgaloader`.
It also fetches **oss-cad-suite** (yosys + nextpnr-himbaechel + apycula) into
`~/.local/oss-cad-suite` — this is a prebuilt bundle, *not* a Homebrew formula. Add it to PATH:

```bash
export PATH="$HOME/.local/oss-cad-suite/bin:$PATH"   # add to ~/.zshrc to persist
```

Separately, install the **Gowin IDE** to `/Applications/GowinIDE.app` (the primary, signoff build
path). The headless shell it ships (`gw_sh`) must run with `DYLD_LIBRARY_PATH` and
`DYLD_FRAMEWORK_PATH` set — this is already encoded in `tools/build/gowin_build.sh`, so always go
through `make build`, never invoke `gw_sh` directly.

### 2. Verify the environment

```bash
make check-env
```

Checks `iverilog`, `openFPGALoader`, that `gw_sh` launches headlessly, and whether a board is on
USB. Prints `PASS:` / `FAIL:` / `INFO:` lines.

### 3. Simulate — this is the gate, not the build

```bash
make simq-all          # full regression across all 12 sim targets, ~57 s, under Verilator
make simq SIM_TARGET=passthrough    # one target, fast inner loop (Verilator, 19× faster than Icarus)
make sim  SIM_TARGET=passthrough    # second opinion under Icarus (~4 min), on demand
```

Every testbench prints exactly one `PASS: <summary>` or `FAIL: <reason>`.
**Run `make simq-all` before every commit** — `src/common/` is shared by seven targets, so a
change to one phase reaches the others. Neither simulator is "the authority"; they check each
other, and each has caught bugs the other missed.

### 4. Build a bitstream

```bash
make build BUILD_TARGET=passthrough      # Gowin gw_sh — primary, timing-signed-off
make build-oss BUILD_TARGET=passthrough  # yosys + nextpnr — fast lint/sanity second opinion
```

`make build` **fails on setup/hold timing violations**, a missing timing report, or an analysis
that covered zero paths — not just on toolchain exit code. Read the numbers out of
`impl/pnr/project_tr_content.html`. Grep the build log for `WARN` after every build.

### 5. Flash

```bash
make flash-sram BUILD_TARGET=passthrough   # volatile, fast iteration
make flash      BUILD_TARGET=passthrough   # persist to onboard flash (survives power cycle)
```

Flashing uses `openFPGALoader -b tangnano20k`. Note: SRAM config is volatile and the onboard
flash still holds whatever was last persisted — a power blip silently swaps the running design.

### 6. Standalone passthrough (the end goal)

```bash
make build BUILD_TARGET=passthrough
make flash BUILD_TARGET=passthrough        # persistent
```

Connect the Prime's flex to the probe pins and the panel to the FFC, then power the board.
It boots in **AUTO**: the panel shows a test grid until the first captured frame lands, then
switches to the live passthrough by itself. No host required.

### 7. Per-phase hardware checks (optional — control + telemetry only)

Each needs its target flashed first (`make flash-sram BUILD_TARGET=<target>`).

| Command | Target | Purpose |
|---|---|---|
| `make selftest-hw` | `bringup_selftest` | UART link + LFSR self-test over serial |
| `make capture-hw` `VCD=captures/x.vcd` | `la_capture` | Arm capture in mock mode, drain, verify pattern |
| `make sdram-hw` | `sdram_selftest` | Write + read back all 8 MB of the in-package SDRAM |
| `make frame-hw` `PPM=out.ppm` | `frame_capture` | Capture one 320×240 frame from the Prime, decode |
| `make lcd-hw` `PATTERN=0..7 BL=0..255` | `lcd_panel` | Verify panel-legal timing; drive test patterns |
| `make pass-hw` `MODE=auto\|mock\|real WATCH=<s>` | `passthrough` | Passthrough telemetry — separates "calculator not driving" from "panel path broken" |

Host-side frame streaming over UART is **retired** (it topped out at ~2 fps — the ceiling was
per-request latency, not bit rate). Phase 4's video path is entirely internal; the host carries a
few bytes per second of control and telemetry only.

---

## Pinouts

The authoritative, fully-annotated reference is
**[`boards/tangnano20k/pinout.md`](boards/tangnano20k/pinout.md)** — every entry there is
cross-checked against the board schematic. Summary tables below.

### Danger pins on the HP Prime flex

☠️ **Do not connect any of these to anything on the Tang Nano:**

| Flex pins | Why |
|---|---|
| **32–42** | TFT gate-driver region: 16.88 V, −8.3 V, −3.3 V rails and 15.4 Vpp swings at 26.3 kHz |
| **3, 4** | 5.5 V |
| **25, 31** | 5 V |
| **35, 36** | 16.88 V / −8.3 V |

Flex pins 19–21 read as noisy ground; pins 1, 2, 5, 6, 45 are ground. The usable logic signals
are only on flex pins **7–18** (see next table).

### HP Prime 45-pin flex → Tang Nano probe wiring (`la_capture`, `passthrough`)

| Prime flex | Signal | Measured | Channel | FPGA pin | Header | Caveat |
|---|---|---|---|---|---|---|
| 7 | DE | 9.8 kHz, 24.7 ms on / 1.96 ms off | `probe[3]` | 51 | R9 | amp `SD_MODE`; also `RPLL2_T_in` (unused) |
| 8 | VSYNC | 37.7 Hz | `probe[2]` | 53 | R19 | ⚠ 2.2 kΩ pull-up to 3V3 (HDMI DDC) |
| 9 | HSYNC | 9.61 kHz | `probe[1]` | 71 | R18 | clean |
| 10 | DOTCLK | 13.1 MHz | `probe[0]` | 80 | R4 | `GCLKT_0`; microSD DAT2 10 kΩ pull-up |
| 11 | D0 | — | `probe[4]` | 72 | R17 | clean |
| 12 | D1 | — | `probe[5]` | 73 | L1 | clean |
| 13 | D2 | — | `probe[6]` | 74 | L2 | clean |
| 14 | D3 | — | `probe[7]` | 85 | L4 | microSD DAT1 10 kΩ pull-up |
| 15 | D4 | — | `probe[8]` | 79 | R14 | `GCLKC_0`; WS2812 data-in via 100 Ω |
| 16 | D5 | — | `probe[9]` | 56 | R7 | SSPI `SO/D1` |
| 17 | D6 | — | `probe[10]` | 54 | R8 | SSPI `DIN/CLKHOLD_N` |
| 18 | D7 | — | `probe[11]` | 55 | R11 | SSPI `SSPI_CS_N/D0` |

**Ground is not optional:** tie the pigtail return to header GND (right header position 2 or 15,
or left header position 20). The five SSPI pins (52–56) are only usable because
`src/targets/la_capture/options.tcl` sets `set_option -use_sspi_as_gpio 1`.

### Tang Nano → replacement panel — 40-pin RGB FPC (`lcd_panel`, `passthrough`)

The board wires **RGB565** (the low colour bits are grounded on the PCB — 24-bit is unreachable
by any adapter).

| Signal | FPGA pins | RTL port | Notes |
|---|---|---|---|
| `LCD_R7..R3` | 38, 39, 40, 41, 42 | `lcd_r[4:0]` | pin 38 = R7 = **MSB** (bit order runs backwards vs pin numbers) |
| `LCD_G7..G2` | 32, 33, 34, 35, 36, 37 | `lcd_g[5:0]` | FFC-socket only, not on the 2×20 headers |
| `LCD_B7..B3` | 27, 28, 29, 30, 31 | `lcd_b[4:0]` | |
| `LCD_CK` | 77 | `lcd_ck` | `GCLKT_1` |
| `LCD_HS` | 25 | `lcd_hs` | active low |
| `LCD_VS` | 26 | `lcd_vs` | active low |
| `LCD_DE` | 48 | `lcd_de` | active high |
| `LCD_BL` | 49 | `lcd_bl` | backlight enable — ⚠️ **pulled up on the board, defaults ON**; only an actively driven low turns it off |
| `LCD_INT0..3` | 15, 16, 17, 18 | — | ⚠ shared with `leds[0..3]` |

`passthrough` ships `BL_DUTY_INIT = 255` (it is a flashed standalone box with a panel permanently
mated); `lcd_panel` ships `0` (backlight opt-in — **measure the LED current before raising it**).
Backlight dimming works at **200 Hz** PWM (`make pass-hw BLHZ=200 SWEEP=1`), not at 1 kHz.

### UART / programming (onboard BL616)

| Signal | FPGA pin | Notes |
|---|---|---|
| `uart_rx` | 70 | host → FPGA (`PIN70_SYS_RX`) |
| `uart_tx` | 69 | FPGA → host (`PIN69_SYS_TX`) |
| `clk` | 4 | 27 MHz oscillator — `LPLL1_T_in`, a PLL reference input, **not** a global-clock pin. Designs instantiate an `rPLL` |
| `leds[0..5]` | 15–20 | onboard LEDs, **active-low** |

Verified at **1,000,000 baud** (27 MHz / 1 MBaud = DIV 27, exact). The BL616 shows up as FTDI
VID:PID `0403:6010` with two interfaces: **A = JTAG** (echoes writes — looks like a working link
but isn't a UART), **B = the UART** you want. `python/tools/` scripts sort by device name and
take the last.

⚠️ **There is no safe external reset pin on this board.** Pin 88 is `MODE0` and pin 87 is `MODE1`
(configuration straps); pins 13/75/76/86 wire to the BL616. All designs use an internal
power-on reset.

---

## The reverse-engineered bus — at a glance

Full spec with measurement evidence: [`docs/prime_lcd_protocol.md`](docs/prime_lcd_protocol.md).

| | |
|---|---|
| Resolution | 320 × 240 |
| Interface | 8-bit parallel, **serial RGB** — 3 DOTCLKs per pixel, component order **R, G, B** |
| DOTCLK | 13.289 MHz, ~53 % duty. **Latch on the rising edge** (data changes on the falling edge) |
| Line | 1361 DOTCLKs = 102.435 µs = 9.762 kHz |
| Frame | 259 lines = 26.53 ms = **37.70 Hz** |
| Blanking | bus is actively driven to `0x00` outside DE (not tri-stated) |
| Logic | 3.3 V CMOS |

The Prime's timing is **illegal for the replacement panel in every temporal respect** (DOTCLK
13.1 MHz vs a 5–8 MHz spec, line 102 µs vs 55–65 µs, frame 37.7 Hz vs ~58–68 Hz). Only the
resolution matches — which is why Phase 4 must capture, buffer, and re-emit on independently
generated panel-legal timing rather than wiring through.

---

## Documentation

| File | Contents |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Toolchain paths, full command table, every known board gotcha |
| [`docs/architecture.md`](docs/architecture.md) | Signal theory, toolchain decisions, phase roadmap |
| [`docs/prime_lcd_protocol.md`](docs/prime_lcd_protocol.md) | The reverse-engineered bus, every figure measured |
| [`docs/panel_afy320240a0.md`](docs/panel_afy320240a0.md) | Replacement-panel compatibility analysis + timing recipe |
| [`docs/sdram.md`](docs/sdram.md) | The custom SDRAM controller |
| [`docs/verification.md`](docs/verification.md) | Why verification comes before synthesis here — the PASS/FAIL contract, two-simulator strategy, mutation testing |
| [`docs/fpga_project_playbook.md`](docs/fpga_project_playbook.md) | Board- and vendor-agnostic distillation, written to seed a new repo |
| [`boards/tangnano20k/pinout.md`](boards/tangnano20k/pinout.md) | The authoritative pin reference |
| [`PROGRESS.md`](PROGRESS.md) | Session log, newest first — read before assuming anything above was run this session |

---

## License

MIT — see [`LICENSE`](LICENSE).
