SIM_TARGET   ?= bringup_uart_loopback
BUILD_TARGET ?= bringup_selftest
VCD          ?=

.PHONY: sim build build-oss flash flash-sram selftest-hw capture-hw check-env clean

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
check-env:    ; tools/setup/check_env.sh
clean:        ; rm -rf impl build_oss sim/.build
