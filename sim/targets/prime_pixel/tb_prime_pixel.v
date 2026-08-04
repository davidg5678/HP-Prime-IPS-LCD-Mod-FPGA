`timescale 1ns/1ps
`default_nettype none
//
// Unit testbench for src/common/prime_pixel.v, at the REAL measured HP Prime
// timing: 1361 DOTCLKs per line, 242 back porch, 960 active, 259 lines.
//
// The stimulus is src/common/video_timing_gen.v -- Phase 1's mock source, an
// INDEPENDENT implementation of the same protocol written months before this
// module and verified against the calculator itself. Agreement between them is
// evidence rather than tautology, which is the same argument
// sim/targets/frame_capture makes. The chain under test is the real one:
//
//     video_timing_gen -> dotclk_sampler -> prime_pixel
//
// so runt rejection and the sampler's edge tracking are in the path too.
//
// video_timing_gen's pattern, per its own header:
//     R = x[7:0]   G = y[7:0]   B = x[7:0] ^ y[7:0]
// with x an 8-bit counter that WRAPS at 256 within a 320-pixel line. The oracle
// below reproduces that wrap explicitly; getting it wrong would look like a
// decoder fault at exactly column 256, which is worth naming because that is
// where a lazy oracle would diverge.
//
module tb_prime_pixel;
    localparam real CLK_NS = 9.259259;      // 108 MHz

    // docs/prime_lcd_protocol.md, measured. DOTCLK_DIV=8 gives 13.5 MHz against
    // the measured 13.289 -- the sampler tracks the edges it is given, so the
    // exact rate is immaterial here and a divisor of 8 keeps the run short.
    localparam integer P_H_TOTAL  = 1361, P_H_SYNC = 1, P_H_START = 242,
                       P_H_ACTIVE = 960;   // 960 / 3 = 320.00 pixels exactly
    localparam integer P_V_TOTAL  = 259,  P_V_SYNC = 1, P_V_START = 19,
                       P_V_ACTIVE = 240;

    localparam integer EXP_X = 320, EXP_Y = 240;

    reg clk = 1'b0, rst_n = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    // ---------------------------------------------------------------- source
    wire       src_dotclk, src_hs, src_vs, src_de;
    wire [7:0] src_d;

    video_timing_gen #(
        .DOTCLK_DIV(8),
        .H_TOTAL(P_H_TOTAL), .H_SYNC(P_H_SYNC), .H_START(P_H_START),
        .H_ACTIVE(P_H_ACTIVE),
        .V_TOTAL(P_V_TOTAL), .V_SYNC(P_V_SYNC), .V_START(P_V_START),
        .V_ACTIVE(P_V_ACTIVE)
    ) u_src (
        .clk(clk), .rst_n(rst_n), .restart(1'b0),
        .dotclk(src_dotclk), .hsync(src_hs), .vsync(src_vs), .de(src_de),
        .data(src_d)
    );

    // Packed exactly as la_capture/frame_capture pack it:
    //   bit0 HSYNC, bit1 VSYNC, bit2 DE, bits 3..10 D0..D7
    wire [10:0] bus = {src_d, src_de, src_vs, src_hs};

    wire        smp_valid;
    wire [10:0] smp;
    wire [15:0] runts;
    dotclk_sampler u_smp (
        .clk(clk), .rst_n(rst_n), .arm(1'b0),
        .dotclk_s(src_dotclk), .bus_s(bus),
        .sample_valid(smp_valid), .sample(smp), .runts(runts)
    );

    wire        pix_valid, frame_start;
    wire [15:0] pix, lines_seen, px_in_line;
    wire [9:0]  pix_x, pix_y;
    prime_pixel #(.MAX_X(EXP_X), .MAX_Y(EXP_Y)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(smp_valid), .sample(smp),
        .pix_valid(pix_valid), .pix(pix), .pix_x(pix_x), .pix_y(pix_y),
        .frame_start(frame_start), .lines_seen(lines_seen), .px_in_line(px_in_line)
    );

    // ---------------------------------------------------------------- oracle
    function [15:0] expect_pix(input integer x, input integer y);
        integer r8, g8, b8;
        begin
            r8 = x % 256;              // video_timing_gen's x is an 8-bit counter
            g8 = y % 256;
            b8 = r8 ^ g8;
            expect_pix = {r8[7:3], g8[7:2], b8[7:3]};
        end
    endfunction

    integer errors = 0;
    integer frames = 0;
    integer px_seen = 0, px_bad = 0, coord_bad = 0;
    integer exp_x = 0, exp_y = 0;
    reg     checking = 1'b0;
    integer f_lines = -1, f_pxline = -1;

    always @(posedge clk) begin
        if (frame_start) begin
            if (checking) begin
                f_lines  = lines_seen;
                f_pxline = px_in_line;
            end
            frames  = frames + 1;
            exp_x   = 0;
            exp_y   = 0;
            checking = 1'b1;     // from the first frame boundary onwards
        end else if (pix_valid && checking) begin
            px_seen = px_seen + 1;
            if (pix_x !== exp_x[9:0] || pix_y !== exp_y[9:0]) begin
                if (coord_bad < 5)
                    $display("FAIL: coordinate: got (%0d,%0d) expected (%0d,%0d)",
                             pix_x, pix_y, exp_x, exp_y);
                coord_bad = coord_bad + 1;
            end
            if (pix !== expect_pix(exp_x, exp_y)) begin
                if (px_bad < 5)
                    $display("FAIL: pixel (%0d,%0d): got %04h expected %04h",
                             exp_x, exp_y, pix, expect_pix(exp_x, exp_y));
                px_bad = px_bad + 1;
            end
            exp_x = exp_x + 1;
            if (exp_x == EXP_X) begin
                exp_x = 0;
                exp_y = exp_y + 1;
            end
        end
    end

    task chk_i(input [1023:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %0d, expected %0d", what, got, exp);
                errors = errors + 1;
            end else $display("  ok  %0s = %0d", what, got);
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        rst_n <= 1'b1;

        // Two frame boundaries: one to synchronise on, one to close a complete
        // frame between them.
        wait (frames >= 2);
        @(posedge clk);

        $display("--- one complete source frame, decoded ---");
        chk_i("pixels decoded",        px_seen,   EXP_X * EXP_Y);
        chk_i("pixel value mismatches", px_bad,   0);
        chk_i("coordinate mismatches",  coord_bad, 0);
        chk_i("lines reported at frame end", f_lines,  EXP_Y);
        chk_i("pixels in the last line",     f_pxline, EXP_X);
        // The sampler must find nothing to reject: video_timing_gen produces a
        // clean divided clock, so any runt here is a sampler bug, not noise.
        chk_i("runt DOTCLK edges", runts, 0);

        if (errors != 0) begin
            $display("FAIL: %0d checks failed", errors);
            $fatal(1);
        end
        $display("PASS: prime_pixel decoded %0d x %0d = %0d pixels exactly from a %0d-DOTCLK line at real Prime timing, 0 coordinate errors, 0 runts",
                 EXP_X, EXP_Y, px_seen, P_H_TOTAL);
        $finish;
    end

    // Two source frames at 1361 x 259 x 8 clocks is ~52 ms. 90 ms leaves room.
    initial begin
        #90_000_000;
        $display("FAIL: watchdog -- %0d frames, %0d pixels, %0d bad",
                 frames, px_seen, px_bad);
        $fatal(1);
    end
endmodule
`default_nettype wire
