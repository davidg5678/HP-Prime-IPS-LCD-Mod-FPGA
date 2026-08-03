SIM_TARGET   ?= bringup_uart_loopback
BUILD_TARGET ?= bringup_selftest
VCD          ?=
PPM          ?=

.PHONY: sim build build-oss flash flash-sram selftest-hw capture-hw sdram-hw frame-hw stream-hw check-env clean

sim:          ; tools/sim/run_sim.sh $(SIM_TARGET)
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
check-env:    ; tools/setup/check_env.sh
clean:        ; rm -rf impl build_oss sim/.build
