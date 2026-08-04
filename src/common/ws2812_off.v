`timescale 1ns/1ps
`default_nettype none
//
// Hold the Tang Nano 20K's onboard WS2812 RGB LED dark.
//
// WHY THIS NEEDS A PROTOCOL DRIVER AND NOT A CONSTRAINT
//
// A WS2812 latches the colour it was last sent and holds it indefinitely. It
// does not default to off, and it does not revert when its data line goes
// quiet -- the >50 us low period is a FRAME DELIMITER, not a reset. So:
//
//   * leaving pin 79 unassigned lets the data line float, pick up noise, and
//     latch some arbitrary bright colour (which is what it does today);
//   * tying it low in the .cst does not help either, because a permanently low
//     line is just an endless inter-frame gap.
//
// The only way to make the part dark is to send it 24 zero bits. Hence this.
//
// It re-sends continuously rather than once at reset. A single frame at
// power-on would be undone by any noise glitch that the part happened to
// interpret as a bit, and the cost of repeating is one pin toggling at 30 us
// intervals a thousand times a second.
//
// TIMING (WS2812B, at 108 MHz where one cycle is 9.259 ns):
//     T0H  0.40 us  +/-150 ns  ->  43 cycles
//     bit  1.25 us             -> 135 cycles   (so T0L = 92 cycles = 0.85 us)
//     reset  > 50 us           -> 6000 cycles = 55.6 us
// Only zero bits are ever sent, so T1H/T1L are not needed. The +/-150 ns
// tolerance is 16 cycles, so the one-cycle lag from registering the output is
// immaterial.
//
// PIN CONFLICT, worth knowing before reusing this: pin 79 is the WS2812 data
// input (through 100 ohm) AND `probe[8]` -- the HP Prime's D4 -- in every
// capture target. A design that captures cannot also silence this LED. See
// boards/tangnano20k/pinout.md.
//
module ws2812_off #(
    parameter integer T0H_CYCLES   = 43,
    parameter integer BIT_CYCLES   = 135,
    parameter integer RESET_CYCLES = 6000
) (
    input  wire clk,
    input  wire rst_n,
    output reg  dout
);
    localparam [12:0] T0H_W   = T0H_CYCLES;
    localparam [12:0] BIT_W   = BIT_CYCLES;
    localparam [12:0] RESET_W = RESET_CYCLES;

    reg [12:0] cnt;
    reg [4:0]  bit_i;      // 0..23
    reg        sending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 13'd0; bit_i <= 5'd0; sending <= 1'b0; dout <= 1'b0;
        end else if (!sending) begin
            // Inter-frame gap: line low, long enough to delimit the frame.
            dout <= 1'b0;
            if (cnt >= RESET_W - 13'd1) begin
                cnt     <= 13'd0;
                bit_i   <= 5'd0;
                sending <= 1'b1;
            end else cnt <= cnt + 13'd1;
        end else begin
            // 24 zero bits: high for T0H, low for the rest of the bit period.
            dout <= (cnt < T0H_W);
            if (cnt >= BIT_W - 13'd1) begin
                cnt <= 13'd0;
                if (bit_i == 5'd23) begin
                    sending <= 1'b0;
                end else bit_i <= bit_i + 5'd1;
            end else cnt <= cnt + 13'd1;
        end
    end
endmodule
`default_nettype wire
