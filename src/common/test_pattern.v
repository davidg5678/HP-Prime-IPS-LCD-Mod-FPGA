`timescale 1ns/1ps
`default_nettype none
//
// RGB565 test-image source for Phase 3, and the MOCK half of Phase 4's mux.
//
// Purely combinational: given a pixel coordinate it returns a colour. It has no
// timing of its own, which is the point -- lcd_timing_gen owns all the timing
// and this owns all the content, so Phase 4 replaces this one module with an
// SDRAM frame-buffer reader and changes nothing else.
//
// WHY RGB565 AND NOT 24-BIT. The panel accepts 24-bit, but the Tang Nano's PCB
// ties R2..R0, G1..G0 and B2..B0 to ground at the FPC connector. That is a
// property of the BOARD, not of the panel, and no adapter can recover those
// bits because the FPGA pins are not routed to those connector positions. See
// docs/panel_afy320240a0.md. So 5:6:5 is the ceiling, and the low bits the
// panel sees are always zero -- meaning our 31 is the panel's 248, not 255.
//
// ---------------------------------------------------------------------------
// THE PATTERNS ARE DIAGNOSTICS, NOT DECORATION
// ---------------------------------------------------------------------------
// Each one fails in a distinguishable way, so first light tells you WHICH thing
// is wrong rather than just that something is:
//
//   0 GRID     1-px border + 32-px grid + centre crosshair.
//              GEOMETRY. If the right or bottom border line is missing, DE is
//              one pixel short or the active window is misaligned -- the exact
//              off-by-one that Thbp-includes-Thw would cause. A border is the
//              only pattern where an off-by-one is visible at all; on a ramp or
//              a photo it is invisible.
//   1 BARS     8 vertical bars, 40 px each, W/Y/C/G/M/R/B/K.
//              CHANNEL WIRING. A swapped R/B shows instantly; a stuck channel
//              turns one bar into another. Bar edges every 40 px also confirm
//              horizontal scale.
//   2 RAMPS    Per-channel 256-px ramps in three horizontal bands.
//              BIT ORDER WITHIN A CHANNEL. A swapped bit inside one channel is
//              invisible on bars (which only use 0 and full scale) but shows on
//              a ramp as a staircase that jumps backwards. The ramp is 256 px
//              inside a 320-px line, so its left and right margins also confirm
//              the active window independently of pattern 0.
//   3 PLAID    R=x, G=y, B=x^y -- Phase 1's mock pattern, ported to 565.
//              CONTINUITY. This is the same image src/common/video_timing_gen.v
//              feeds the capture path, so a Phase 4 loopback (mock video in ->
//              capture -> SDRAM -> panel out) can be compared against this by
//              eye and by capture.
//   4 WHITE    Backlight uniformity and current draw. The panel wants 19.2 V at
//              40 mA and its absolute max is 50 mA; the board's boost driver was
//              designed for Sipeed's 4.3" panel. This is the pattern to measure
//              current on before running anything continuously.
//   5 BLACK    Contrast floor, and confirms the panel is not simply showing
//              backlight through an undriven cell.
//   6 THIRDS   Solid R / G / B bands. Coarser than BARS -- readable across a
//              room, useful when the panel is on a bench and you are at a
//              keyboard.
//   7 CHECKER  1-px checkerboard.
//              SIGNAL INTEGRITY. The fastest content the panel can ever be
//              asked to display: every data line toggles at 3 MHz. If DCLK
//              phase or FFC length is marginal, this smears or shimmers while
//              every other pattern looks perfect.
//
module test_pattern (
    input  wire [9:0] x,        // 0..319
    input  wire [9:0] y,        // 0..239
    input  wire [2:0] sel,
    output reg  [4:0] r,        // R7..R3 on the connector
    output reg  [5:0] g,        // G7..G2
    output reg  [4:0] b         // B7..B3
);
    localparam [2:0] P_GRID = 3'd0, P_BARS = 3'd1, P_RAMPS = 3'd2, P_PLAID = 3'd3,
                     P_WHITE= 3'd4, P_BLACK= 3'd5, P_THIRDS= 3'd6, P_CHECK = 3'd7;

    // -------------------------------------------------------------- geometry
    wire on_border = (x == 10'd0) || (x == 10'd319) || (y == 10'd0) || (y == 10'd239);
    wire on_grid   = (x[4:0] == 5'd0) || (y[4:0] == 5'd0);
    wire on_cross  = (x == 10'd160) || (y == 10'd120);

    // ------------------------------------------------------------------ bars
    // 40 px each. A comparison chain rather than x/40: division by a non-power
    // of two costs real logic and this is on the pixel path.
    reg [2:0] bar;
    always @(*) begin
        if      (x < 10'd40)  bar = 3'd0;
        else if (x < 10'd80)  bar = 3'd1;
        else if (x < 10'd120) bar = 3'd2;
        else if (x < 10'd160) bar = 3'd3;
        else if (x < 10'd200) bar = 3'd4;
        else if (x < 10'd240) bar = 3'd5;
        else if (x < 10'd280) bar = 3'd6;
        else                  bar = 3'd7;
    end
    // W Y C G M R B K, in that order -- the standard colour-bar sequence, so a
    // reversed scan direction is obvious rather than merely "different".
    wire bar_r = (bar == 3'd0) || (bar == 3'd1) || (bar == 3'd4) || (bar == 3'd5);
    wire bar_g = (bar == 3'd0) || (bar == 3'd1) || (bar == 3'd2) || (bar == 3'd3);
    wire bar_b = (bar == 3'd0) || (bar == 3'd2) || (bar == 3'd4) || (bar == 3'd6);

    // ----------------------------------------------------------------- ramps
    // 256 px wide starting at x = 32, so the step is a shift rather than a
    // divide: 8 px per code for 5-bit channels, 4 px per code for 6-bit green.
    wire       in_ramp = (x >= 10'd32) && (x < 10'd288);
    wire [7:0] rx      = x[7:0] - 8'd32;
    wire [4:0] ramp5   = rx[7:3];
    wire [5:0] ramp6   = rx[7:2];
    wire       band_r  = (y < 10'd80);
    wire       band_g  = (y >= 10'd80) && (y < 10'd160);

    // ----------------------------------------------------------------- plaid
    wire [9:0] xy = x ^ y;

    // ---------------------------------------------------------------- thirds
    wire third_r = (y < 10'd80);
    wire third_g = (y >= 10'd80) && (y < 10'd160);

    always @(*) begin
        case (sel)
            P_GRID: begin
                if (on_border)     begin r = 5'h1F; g = 6'h3F; b = 5'h1F; end
                else if (on_cross) begin r = 5'h1F; g = 6'h00; b = 5'h00; end
                else if (on_grid)  begin r = 5'h08; g = 6'h10; b = 5'h08; end
                else               begin r = 5'h00; g = 6'h00; b = 5'h00; end
            end
            P_BARS: begin
                r = bar_r ? 5'h1F : 5'h00;
                g = bar_g ? 6'h3F : 6'h00;
                b = bar_b ? 5'h1F : 5'h00;
            end
            P_RAMPS: begin
                r = (in_ramp && band_r)              ? ramp5 : 5'h00;
                g = (in_ramp && band_g)              ? ramp6 : 6'h00;
                b = (in_ramp && !band_r && !band_g)  ? ramp5 : 5'h00;
            end
            P_PLAID: begin
                r = x[7:3];
                g = y[7:2];
                b = xy[7:3];
            end
            P_WHITE:  begin r = 5'h1F; g = 6'h3F; b = 5'h1F; end
            P_BLACK:  begin r = 5'h00; g = 6'h00; b = 5'h00; end
            P_THIRDS: begin
                r = third_r ? 5'h1F : 5'h00;
                g = third_g ? 6'h3F : 6'h00;
                b = (!third_r && !third_g) ? 5'h1F : 5'h00;
            end
            default: begin  // P_CHECK
                r = xy[0] ? 5'h1F : 5'h00;
                g = xy[0] ? 6'h3F : 6'h00;
                b = xy[0] ? 5'h1F : 5'h00;
            end
        endcase
    end
endmodule
`default_nettype wire
