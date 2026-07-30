SIM_TARGET   ?= bringup_uart_loopback
BUILD_TARGET ?= bringup_selftest

.PHONY: sim build build-oss flash flash-sram selftest-hw check-env clean

sim:          ; tools/sim/run_sim.sh $(SIM_TARGET)
build:        ; tools/build/gowin_build.sh $(BUILD_TARGET)
build-oss:    ; tools/build/oss_cad_build.sh $(BUILD_TARGET)
flash-sram:   ; tools/build/flash.sh $(BUILD_TARGET)
flash:        ; tools/build/flash.sh $(BUILD_TARGET) --persist
selftest-hw:  ; python3 python/tools/serial_selftest.py
check-env:    ; tools/setup/check_env.sh
clean:        ; rm -rf impl build_oss sim/.build
