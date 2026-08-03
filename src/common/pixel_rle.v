`timescale 1ns/1ps
`default_nettype none
//
// Run-length encoder for the HP Prime's pixel stream.
//
// Takes the per-DOTCLK sample stream from dotclk_sampler, assembles R,G,B
// triplets during DE, and emits runs as four bytes: count, R, G, B.
//
// WHY RLE AND NOT SOMETHING CLEVERER: measured on a real captured frame, pixel
// RLE takes 230,400 bytes of active data down to 49,864 -- 4.6x. That is
// entirely because a calculator UI is mostly flat colour: 74% of one real frame
// was a single white. Over a 1 Mbaud link that is the difference between 0.43
// and 2.0 frames per second, and it costs a comparator and a counter.
//
// COUNT IS NEVER ZERO, which is what makes the stream self-framing: the
// transmitter can use 0x00 as an escape byte for frame markers with no risk of
// colliding with run data. Runs are capped at 255 pixels and split, not
// dropped.
//
// Runs deliberately do NOT break at line ends. The host fills a linear pixel
// buffer and wraps at the frame width, so a run spanning the end of one line
// into the next is legitimate and compresses better. It also means a lost byte
// desynchronises everything after it -- which is why each transmitted frame is
// prefixed with a marker rather than relying on position alone.
//
module pixel_rle (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        smp_valid,   // 1-cycle pulse from dotclk_sampler
    input  wire [10:0] smp,         // bit0 HSYNC, bit1 VSYNC, bit2 DE, [10:3] data
    input  wire        frame_start, // pulse: flush and begin a new frame
    input  wire        enable,      // encode only while high

    output reg         byte_valid,
    output reg  [7:0]  byte_out,
    output reg  [31:0] pixels,      // pixels encoded this frame, for the report
    output wire        busy         // a run is still going out; do not stop yet
);
    wire       de   = smp[2];
    wire [7:0] comp = smp[10:3];

    reg [1:0]  phase;        // which component of the pixel is arriving
    reg [7:0]  pr, pg;       // R and G held while B arrives
    reg [23:0] run_rgb;
    reg [7:0]  run_len;
    reg        have_run;

    // Four-byte emitter. A pixel arrives every 3 DOTCLKs (~24 cycles at
    // 108 MHz) and a run is at most 4 bytes, so even a stream of
    // single-pixel runs -- the worst case -- has ample room.
    // THREE bits, counting 4->3->2->1->0. A run is FOUR bytes and an earlier
    // version used a 2-bit counter stepping 3->2->1, which is only three
    // emission steps: the final step assigned both G and B, the `if` overrode
    // the `case`, and G was silently dropped from every run. Three bytes went
    // out where the decoder expected four, so the entire stream slid out of
    // alignment and produced runs with a count of zero -- a value the encoder
    // cannot legitimately emit.
    reg [2:0]  emit;         // bytes still to send, 0 = idle
    reg [23:0] emit_rgb;
    reg [7:0]  emit_len;

    // Includes the cycle on which the flush is INITIATED. `emit` is set by a
    // non-blocking assignment, so on the frame_start cycle it still reads zero;
    // a consumer polling `emit != 0` alone would conclude the encoder was idle
    // and move on one cycle before the final run's four bytes appeared, losing
    // the last run of every frame.
    assign busy = (emit != 3'd0) || (frame_start && have_run);

    wire       pixel_done = smp_valid && de && (phase == 2'd2);
    wire [23:0] pixel_rgb = {pr, pg, comp};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 2'd0; pr <= 8'd0; pg <= 8'd0;
            run_rgb <= 24'd0; run_len <= 8'd0; have_run <= 1'b0;
            emit <= 3'd0; emit_rgb <= 24'd0; emit_len <= 8'd0;
            byte_valid <= 1'b0; byte_out <= 8'd0; pixels <= 32'd0;
        end else begin
            byte_valid <= 1'b0;

            // ---- emitting a pending run, most significant field first
            if (emit != 3'd0) begin
                byte_valid <= 1'b1;
                case (emit)
                    3'd4:    byte_out <= emit_len;
                    3'd3:    byte_out <= emit_rgb[23:16];   // R
                    3'd2:    byte_out <= emit_rgb[15:8];    // G
                    default: byte_out <= emit_rgb[7:0];     // B
                endcase
                emit <= emit - 3'd1;
            end

            if (frame_start) begin
                // Flush whatever run is open; the frame boundary ends it.
                if (have_run) begin
                    emit     <= 3'd4;
                    emit_len <= run_len;
                    emit_rgb <= run_rgb;
                end
                have_run <= 1'b0;
                run_len  <= 8'd0;
                phase    <= 2'd0;
                pixels   <= 32'd0;
            end else if (enable && smp_valid) begin
                if (!de) begin
                    // Blanking resets only the component phase: a run may span
                    // the DE gap between lines, which is the point.
                    phase <= 2'd0;
                end else begin
                    if (phase == 2'd0)      pr    <= comp;
                    else if (phase == 2'd1) pg    <= comp;
                    phase <= (phase == 2'd2) ? 2'd0 : phase + 2'd1;

                    if (pixel_done) begin
                        pixels <= pixels + 32'd1;
                        if (have_run && pixel_rgb == run_rgb && run_len != 8'hFF) begin
                            run_len <= run_len + 8'd1;
                        end else begin
                            if (have_run) begin
                                emit     <= 3'd4;
                                emit_len <= run_len;
                                emit_rgb <= run_rgb;
                            end
                            run_rgb  <= pixel_rgb;
                            run_len  <= 8'd1;
                            have_run <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
