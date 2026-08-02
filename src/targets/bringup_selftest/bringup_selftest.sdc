// Timing constraints for bringup_selftest.
//
// tools/build/gowin_build.sh picks this file up automatically if it is named
// <target>.sdc alongside <target>.cst -- no script change needed.
//
// Without this file gw_sh emits "WARN (TA1132) 'clk' was determined to be a
// clock but was not created" and runs NO timing analysis at all. The build
// still succeeds, which is precisely the silent-failure mode docs/verification.md
// warns about: an unconstrained design reports no timing violations because
// nothing checked for any. Harmless at 27 MHz on a design this small; not
// harmless once Phase 1 adds BSRAM, a PLL and a second clock domain.
//
// 27 MHz onboard oscillator on pin 4: period = 1000/27 = 37.037 ns.
//
// Result with this constraint in place: 351 paths analysed, 0 setup and 0 hold
// violations, Fmax 205.4 MHz vs the 27 MHz requirement (7.6x margin). That
// agrees with nextpnr-himbaechel's independent ~248 MHz estimate.
//
// One warning remains and is understood, not merely tolerated:
//   WARN (PR1014) Generic routing resource will be used to clock signal 'clk_d'
// Pin 4's Function column in impl/pnr/project.rpt.txt reads LPLL1_T_in -- it is
// the dedicated reference input of the left PLL, not a GCLK_PIN (the report
// shows GCLK_PIN 0/5 used). Bypassing the PLL means the first hop onto the
// PRIMARY global network goes through generic routing. Harmless here; the
// correct fix is to feed pin 4 into an rPLL, which is what Phase 1 does anyway
// for its oversampling clock, and a PLL output reaches a global buffer natively.
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// uart_rx is an asynchronous input from the BL616 -- it is resynchronised by
// the 2-FF synchroniser at the top of src/common/uart_rx.v, so there is no
// meaningful setup/hold relationship to the 27 MHz domain and the analyser
// should not try to invent one.
set_false_path -from [get_ports {uart_rx}]

// rst (pin 88 / MODE0) is a diagnostic level driven straight to leds[4] and is
// deliberately NOT in the reset path. Purely combinational, no timing to meet.
set_false_path -from [get_ports {rst}]

// LEDs are human-visible indicators; nanoseconds of skew are irrelevant.
set_false_path -to [get_ports {leds[*]}]
