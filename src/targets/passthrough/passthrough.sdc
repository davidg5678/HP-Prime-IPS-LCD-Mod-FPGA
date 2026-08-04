// Timing constraints for passthrough (Phase 4).
//
// Without this file gw_sh emits WARN (TA1132) and runs NO static timing
// analysis at all while still reporting a clean build -- zero violations
// because it checked zero paths. See docs/verification.md.
//
// Only the 27 MHz reference is declared; the 108 MHz system clock is derived by
// the analyser from the rPLL's divider settings. Confirm after each build that
// the Clock Summary in impl/pnr/project_tr_content.html still lists
// u_pll/u_rpll/CLKOUT as a Generated clock at 108 MHz derived from clk27.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// The twelve probe inputs come from a different board with its own oscillator
// -- that is the entire point. src/common/sync2.v resynchronises all of them,
// so there is no real setup/hold relationship for the analyser to invent.
set_false_path -from [get_ports {probe[*]}]

// uart_rx is likewise asynchronous, resynchronised inside src/common/uart_rx.v.
set_false_path -from [get_ports {uart_rx}]

set_false_path -to [get_ports {leds[*]}]

// Panel outputs: false-pathed for the reasons set out at length in
// src/targets/lcd_panel/lcd_panel.sdc -- there is no external clock to
// constrain them against, since the FPGA generates DCLK itself, and the skew
// that actually matters is met by construction with 25 ns of slack (data moves
// at phase 0, DCLK's edges are at phases 4 and 13, the panel needs 12 ns).
// Writing a set_output_delay here would mean inventing a relationship rather
// than describing one. The register-to-register paths feeding these outputs
// remain fully analysed; only the final flop-to-pad hop is exempt.
set_false_path -to [get_ports {lcd_r[*]}]
set_false_path -to [get_ports {lcd_g[*]}]
set_false_path -to [get_ports {lcd_b[*]}]
set_false_path -to [get_ports {lcd_ck}]
set_false_path -to [get_ports {lcd_hs}]
set_false_path -to [get_ports {lcd_vs}]
set_false_path -to [get_ports {lcd_de}]
set_false_path -to [get_ports {lcd_bl}]
