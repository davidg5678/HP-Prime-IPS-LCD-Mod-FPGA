// Timing constraints for la_capture.
//
// tools/build/gowin_build.sh picks this up automatically because it is named
// <target>.sdc alongside <target>.cst. Without it gw_sh emits
//   WARN (TA1132) 'clk' was determined to be a clock but was not created
// and runs NO static timing analysis at all while still reporting a clean
// build -- zero violations because it checked zero paths. See
// docs/verification.md; that silent-success mode is the thing this repo keeps
// getting caught by.
//
// Only the 27 MHz reference is declared. Everything in the design runs on the
// rPLL's 108 MHz output, and Gowin's analyser derives that generated clock
// from the primitive's divider settings -- declaring it by hand would risk
// disagreeing with the hardware. Confirmed rather than assumed: the Clock
// Summary in impl/pnr/project_tr_content.html lists
//   u_pll/u_rpll/CLKOUT.default_gen_clk  Generated  9.259 ns  108.000 MHz
// derived from clk27, and 3739 paths are analysed against it with 0 setup and
// 0 hold violations at Fmax 134.8 MHz. If that derived clock ever stops
// appearing in that table, the analysis is covering far less than it appears
// to and this file needs a create_generated_clock added by hand.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// The twelve probe inputs are asynchronous by definition -- they come from a
// different board with its own oscillator, which is the entire point of a
// logic analyser. src/common/sync2.v resynchronises all of them, so there is
// no real setup/hold relationship for the analyser to invent.
set_false_path -from [get_ports {probe[*]}]

// uart_rx is likewise asynchronous, and is resynchronised by the 2-FF
// synchroniser at the top of src/common/uart_rx.v.
set_false_path -from [get_ports {uart_rx}]

// LEDs are human-visible indicators; nanoseconds of skew are irrelevant.
set_false_path -to [get_ports {leds[*]}]
