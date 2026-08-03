// Timing constraints for sdram_selftest. Without an .sdc, gw_sh runs no timing
// analysis at all and reports zero violations because it checked zero paths --
// and tools/build/gowin_build.sh now fails the build if that happens.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// uart_rx is asynchronous and is resynchronised inside src/common/uart_rx.v.
set_false_path -from [get_ports {uart_rx}]

// LEDs are human-visible; nanoseconds of skew are irrelevant.
set_false_path -to [get_ports {leds[*]}]
