`timescale 1ns/1ps
`default_nettype none
//
// Synchronous sampling of the HP Prime's LCD bus: one sample per DOTCLK,
// latched on the rising edge, with runt edges rejected.
//
// This replaces oversampling for whole-frame work, and it is a change of kind
// rather than of degree:
//
//   * BANDWIDTH. Oversampling at 108 MHz produces 108 MW/s (54 MW/s packed two
//     to a word), against roughly 10.8 MW/s that sdram_ctrl delivers. It simply
//     cannot be stored. One sample per DOTCLK is 13.29 MW/s, 6.64 MW/s packed,
//     which fits with a third to spare. A frame drops from 11 MB to 688 KB.
//
//   * CORRECTNESS. Oversampling an asynchronous 13.29 MHz clock only 8.1x lets
//     the synchroniser occasionally resolve a metastable edge into a one-sample
//     runt -- 2 in 8064 half-periods measured on real captures. One spurious
//     edge shifts every subsequent pixel triplet by a byte and corrupts the rest
//     of the line. python/tools/decode_prime.py works around it host-side; this
//     rejects it at source, where the information to do so is cleanest.
//
// Latching on the RISING edge is measured, not assumed: data changes 0-1
// samples after the DOTCLK falling edge, and sweeping the sample point against
// "how many pixels decode with R != G != B" gave zero mixed pixels at offsets
// 0-3 and tens at 4+. See docs/prime_lcd_protocol.md.
//
// Inputs must already be synchronised to clk (sync2 upstream). Both dotclk and
// the bus go through the same synchroniser depth, so their timing relationship
// is preserved and sampling the bus on the cycle the edge is detected is the
// offset-0 case the sweep validated.
//
module dotclk_sampler #(
    // Minimum cycles between two accepted rising edges. The DOTCLK period is
    // 108/13.289 = 8.1 cycles, so nothing real can arrive sooner than about
    // half that. This is an exact bound, not a guess: it rejects only intervals
    // that are physically impossible for the measured clock.
    parameter integer MIN_SPACING = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        arm,           // 1-cycle pulse: restart edge tracking
    input  wire        dotclk_s,      // synchronised DOTCLK
    input  wire [10:0] bus_s,         // synchronised {D7..D0, DE, VSYNC, HSYNC}
    output reg         sample_valid,  // 1-cycle pulse
    output reg  [10:0] sample,
    output reg  [15:0] runts          // rejected edges, for the status report
);
    reg       dotclk_d;
    reg [3:0] since;                  // cycles since the last accepted edge

    wire rise    = dotclk_s && !dotclk_d;
    wire spaced  = (since >= MIN_SPACING[3:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dotclk_d     <= 1'b0;
            since        <= 4'hF;
            sample_valid <= 1'b0;
            sample       <= 11'd0;
            runts        <= 16'd0;
        end else begin
            dotclk_d     <= dotclk_s;
            sample_valid <= 1'b0;

            if (arm) begin
                // Saturated, so the first edge after arming is always accepted:
                // there is no previous edge for it to be too close to.
                since <= 4'hF;
                runts <= 16'd0;
            end else if (since != 4'hF) begin
                since <= since + 4'd1;
            end

            if (rise && !arm) begin
                if (spaced) begin
                    sample       <= bus_s;
                    sample_valid <= 1'b1;
                    since        <= 4'd1;
                end else begin
                    // Saturate rather than wrap -- a runt must not reset the
                    // spacing window, or a burst of them would each look
                    // legitimately spaced from the one before.
                    if (runts != 16'hFFFF) runts <= runts + 16'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
