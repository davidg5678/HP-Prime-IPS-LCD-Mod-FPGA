// Timing constraints for lcd_panel.
//
// tools/build/gowin_build.sh picks this up automatically because it is named
// <target>.sdc alongside <target>.cst. Without it gw_sh emits
//   WARN (TA1132) 'clk' was determined to be a clock but was not created
// and runs NO static timing analysis at all while still reporting a clean
// build -- zero violations because it checked zero paths. See
// docs/verification.md.
//
// Only the 27 MHz reference is declared. Everything runs on the rPLL's 108 MHz
// output, which Gowin's analyser derives from the primitive's divider settings;
// declaring it by hand would risk disagreeing with the hardware. Confirm after
// each build that the Clock Summary in impl/pnr/project_tr_content.html still
// lists u_pll/u_rpll/CLKOUT as a Generated clock at 108 MHz derived from clk27.
// If it stops appearing there, the analysis is covering far less than it looks
// like and this file needs a create_generated_clock added by hand.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// uart_rx is asynchronous and is resynchronised by the 2-FF synchroniser at the
// top of src/common/uart_rx.v.
set_false_path -from [get_ports {uart_rx}]

// LEDs are human-visible indicators; nanoseconds of skew are irrelevant.
set_false_path -to [get_ports {leds[*]}]

// ---------------------------------------------------------------------------
// THE PANEL OUTPUTS ARE FALSE-PATHED, AND THAT IS A CLAIM THAT NEEDS DEFENDING
// ---------------------------------------------------------------------------
// There is no external clock to constrain these against: the FPGA GENERATES
// DCLK, so a set_output_delay would have to reference a clock this design
// itself produces as ordinary data. Writing one would mean inventing a
// relationship rather than describing one, and an invented constraint that
// passes is worse than no constraint -- it is exactly the "clean build log is
// not a timing signoff" failure this repo has already been caught by once.
//
// What actually has to hold is the skew between lcd_ck and the 17 signals it
// clocks, and that is met by an enormous margin BY CONSTRUCTION rather than by
// the analyser:
//
//   * every one of these pins is driven by a flip-flop in the same 108 MHz
//     domain, with no combinational logic between the flop and the pad;
//   * data, DE, HSYNC and VSYNC all transition at phase 0 of the DCLK period,
//     while DCLK's own edges are at phases 4 and 13 -- so the smallest
//     data-to-clock-edge separation is 4 system clocks = 37.0 ns;
//   * the panel needs 12 ns of setup and 12 ns of hold.
//
// So the design has 25 ns of slack on its worst edge. Clock-to-pad skew between
// pins in the same bank is on the order of a few hundred picoseconds. The
// constraint that matters here is the phase choice in lcd_timing_gen, not a
// line in this file, and that choice is verified numerically in
// sim/targets/lcd_panel/tb_lcd_panel.v -- which measures the actual setup and
// hold margins off the DUT's pins and asserts on nanoseconds, not on cycles.
//
// The register-to-register paths that FEED these outputs are still fully
// analysed; only the final flop-to-pad hop is exempted.
set_false_path -to [get_ports {lcd_r[*]}]
set_false_path -to [get_ports {lcd_g[*]}]
set_false_path -to [get_ports {lcd_b[*]}]
set_false_path -to [get_ports {lcd_ck}]
set_false_path -to [get_ports {lcd_hs}]
set_false_path -to [get_ports {lcd_vs}]
set_false_path -to [get_ports {lcd_de}]

// The backlight is a regulator enable PWMed at ~1 kHz. Nanoseconds are
// meaningless on it.
set_false_path -to [get_ports {lcd_bl}]

// The WS2812 line is a 1.25 us-per-bit software-timed protocol with +/-150 ns
// tolerance -- 16 clock cycles. Nanoseconds of pad delay are irrelevant.
set_false_path -to [get_ports {rgb_led}]
