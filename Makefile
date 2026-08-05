SIM_TARGET   ?= bringup_uart_loopback
BUILD_TARGET ?= bringup_selftest
VCD          ?=
PPM          ?=
PATTERN      ?=
BL           ?=
LEDS         ?=
MODE         ?=
WATCH        ?=
BLHZ         ?=
SWEEP        ?=

.PHONY: sim simq simq-all build build-oss flash flash-sram selftest-hw capture-hw sdram-hw frame-hw stream-hw lcd-hw pass-hw check-env clean

sim:          ; tools/sim/run_sim.sh $(SIM_TARGET)
# Same testbench, same PASS/FAIL contract, Verilator instead of Icarus.
# Measured on tb_passthrough: 4 m 29 s -> 14 s, 19x, identical verdict.
# `sim` remains the reference and the thing to run before a build; `simq` is the
# inner loop. Keeping both is deliberate -- they disagree about what legal
# Verilog is, which is exactly what makes their agreement worth something. See
# the header of tools/sim/run_sim_fast.sh.
simq:         ; tools/sim/run_sim_fast.sh $(SIM_TARGET)
# Full regression across EVERY sim target, under Verilator. Newly practical:
# the same sweep under Icarus was ~30 min, which is long enough that nobody runs
# it. src/common/ is shared by seven targets, so a change to one phase reaches
# the others -- this is the gate that catches that.
simq-all:     ; tools/sim/run_all_fast.sh
build:        ; tools/build/gowin_build.sh $(BUILD_TARGET)
build-oss:    ; tools/build/oss_cad_build.sh $(BUILD_TARGET)
flash-sram:   ; tools/build/flash.sh $(BUILD_TARGET)
flash:        ; tools/build/flash.sh $(BUILD_TARGET) --persist
selftest-hw:  ; python3 python/tools/serial_selftest.py $(if $(PORT),--port $(PORT))
# Phase 1 hardware check: arms the la_capture bitstream in MOCK mode, drains the
# buffer and verifies the synthetic video pattern. Needs `make flash-sram
# BUILD_TARGET=la_capture` first. VCD=<path> also writes a waveform.
capture-hw:   ; python3 python/tools/la_capture.py $(if $(PORT),--port $(PORT)) $(if $(VCD),--vcd $(VCD))
# Full-memory SDRAM test: writes and reads back all 8 MB of the in-package die.
# Needs `make flash-sram BUILD_TARGET=sdram_selftest` first.
sdram-hw:     ; python3 python/tools/sdram_selftest.py $(if $(PORT),--port $(PORT))
# Phase 2: capture a whole 320x240 frame from the Prime into SDRAM and decode
# it. Needs `make flash-sram BUILD_TARGET=frame_capture` first and the probes
# attached. PPM=<path> writes the decoded image.
frame-hw:     ; python3 python/tools/frame_capture.py $(if $(PORT),--port $(PORT)) $(if $(PPM),--ppm $(PPM))
# Live view: continuously capture, RLE-encode into SDRAM and stream frames.
# Needs `make flash-sram BUILD_TARGET=frame_stream` first and the probes
# attached. PPM=captures/live_%d.ppm writes each frame.
stream-hw:    ; python3 python/tools/frame_stream.py $(if $(PORT),--port $(PORT)) $(if $(PPM),--ppm $(PPM))
# Phase 3: verify the FPGA is emitting panel-legal RGB timing, and drive the
# test patterns. Needs `make flash-sram BUILD_TARGET=lcd_panel` first; the panel
# itself needs no host at all, since the video path is entirely internal.
#   PATTERN=0..7  select a test image (0 GRID, 1 BARS, 2 RAMPS, 3 PLAID,
#                 4 WHITE, 5 BLACK, 6 THIRDS, 7 CHECKER)
#   BL=0..255     backlight PWM duty. Comes up at 64 (25%) deliberately --
#                 MEASURE THE LED CURRENT before raising it; see
#                 docs/panel_afy320240a0.md.
lcd-hw:       ; python3 python/tools/lcd_panel.py $(if $(PORT),--port $(PORT)) $(if $(PATTERN),--pattern $(PATTERN)) $(if $(BL),--backlight $(BL)) $(if $(LEDS),--leds $(LEDS))
# Phase 4: control and telemetry for the live passthrough. Needs
# `make flash-sram BUILD_TARGET=passthrough` first, the probes attached to the
# Prime and the panel on J2.
#
# YOU DO NOT NEED THIS TO USE THE PASSTHROUGH. The bitstream powers up in AUTO:
# mock pattern until a captured frame lands, then live passthrough, on its own,
# with no host. `make flash BUILD_TARGET=passthrough` makes that survive a power
# cycle. This target is for when it does NOT happen -- the report separates "the
# calculator is not driving" from "the panel path is broken", which look
# identical on the glass. It carries no pixels; Phase 2's UART streaming is
# retired and is not coming back.
#   MODE=auto|mock|real  force the pixel source (auto = the power-on behaviour)
#   PATTERN=0..7         mock image, as lcd-hw
#   BL=0..255            backlight duty. 255 = static enable = the shipped
#                        default. Intermediate values need BLHZ lowered too.
#   WATCH=<seconds>      poll for this long instead of the default 0.5 s
#   BLHZ=<Hz>            backlight PWM frequency, 103..26400. THE DIMMING
#                        EXPERIMENT: on-time = duty x period must exceed the
#                        LP3320's soft-start or the panel stays dark while
#                        reporting itself lit. 1 kHz cannot dim; try 200.
#   SWEEP=1              walk the duty down at BLHZ, pausing at each step. The
#                        duty where the panel goes dark IS the soft-start.
pass-hw:      ; python3 python/tools/passthrough.py $(if $(PORT),--port $(PORT)) $(if $(MODE),--mode $(MODE)) $(if $(PATTERN),--pattern $(PATTERN)) $(if $(BL),--backlight $(BL)) $(if $(BLHZ),--bl-hz $(BLHZ)) $(if $(SWEEP),--bl-sweep) $(if $(WATCH),--watch $(WATCH))
check-env:    ; tools/setup/check_env.sh
clean:        ; rm -rf impl build_oss sim/.build
