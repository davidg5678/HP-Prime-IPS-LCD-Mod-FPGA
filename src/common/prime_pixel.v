`timescale 1ns/1ps
`default_nettype none
//
// Serial-RGB bus -> RGB565 pixels with coordinates. The Phase 4 front end.
//
// Takes the one-sample-per-DOTCLK stream from src/common/dotclk_sampler.v and
// turns it into addressed pixels a frame buffer can consume. This is the RTL
// equivalent of what python/tools/decode_prime.py does host-side, which makes
// that script an independent oracle for this module rather than a sibling
// implementation -- it decoded the Prime's home screen correctly from real
// captured data, so its bit positions are ground truth.
//
// SAMPLE FORMAT, from src/targets/frame_capture (and matching the host
// decoder's `(s >> 2) & 1` / `(s >> 3) & 0xFF`):
//     bit 0    HSYNC     (active low, unused here)
//     bit 1    VSYNC     (active low)
//     bit 2    DE        (active high)
//     bits 3..10  D0..D7 -- so sample[10:3] is the byte with D7 as its MSB
//
// PIXEL ASSEMBLY. Three consecutive DE-gated bytes are one pixel, in the order
// R, G, B (docs/prime_lcd_protocol.md -- established by displaying a red screen
// and a green screen and reading back `ff 00 00` and `00 ff 00`). The first
// byte after DE rises is R of pixel 0, so the component phase is reset on the
// DE rising edge rather than free-running. That matters: a free-running phase
// that drifts by one byte shifts every pixel boundary for the rest of the
// frame, which is the failure mode docs/prime_lcd_protocol.md calls out under
// "Reject runt DOTCLK edges".
//
// COORDINATES. x counts pixels within a DE run; y counts DE runs since the
// VSYNC falling edge. Deriving y from DE runs rather than from a line counter
// is deliberate -- it is exactly what the host decoder does ("split into lines
// on DE"), and it means a glitch costs one line rather than desynchronising the
// rest of the frame.
//
// 24-bit to RGB565 is straight truncation of the low bits. That is not a
// choice: the Tang Nano's PCB grounds R2..R0, G1..G0 and B2..B0 at the panel
// connector, so those bits are physically unreachable. See
// docs/panel_afy320240a0.md.
//
// MAX_X/MAX_Y clamp `valid` rather than the coordinates. A source that emits
// more pixels per line than expected (a runt edge that survived the sampler,
// or simply a different calculator) then loses the excess instead of writing
// past the end of a frame buffer row.
//
module prime_pixel #(
    parameter integer MAX_X = 320,
    parameter integer MAX_Y = 240
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sample_valid,   // one pulse per DOTCLK
    input  wire [10:0] sample,

    output reg         pix_valid,
    output reg  [15:0] pix,            // RGB565
    output reg  [9:0]  pix_x,
    output reg  [9:0]  pix_y,

    output reg         frame_start,    // pulse on the source's VSYNC falling edge
    output reg  [15:0] lines_seen,     // DE runs in the frame that just ended
    output reg  [15:0] px_in_line      // pixels in the DE run that just ended
);
    wire       s_vs = sample[1];
    wire       s_de = sample[2];
    wire [7:0] s_d  = sample[10:3];

    reg        de_d, vs_d;
    reg [1:0]  comp;        // 0 = expecting R, 1 = G, 2 = B
    reg [7:0]  r_lat, g_lat;
    reg [9:0]  x, y;
    reg [15:0] px_run;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 1'b0; vs_d <= 1'b1;
            comp <= 2'd0; r_lat <= 8'd0; g_lat <= 8'd0;
            x <= 10'd0; y <= 10'd0; px_run <= 16'd0;
            pix_valid <= 1'b0; pix <= 16'd0; pix_x <= 10'd0; pix_y <= 10'd0;
            frame_start <= 1'b0; lines_seen <= 16'd0; px_in_line <= 16'd0;
        end else begin
            pix_valid   <= 1'b0;
            frame_start <= 1'b0;

            if (sample_valid) begin
                de_d <= s_de;
                vs_d <= s_vs;

                if (!s_vs && vs_d) begin
                    // Source VSYNC fell: the previous frame is complete and a
                    // new one starts here. Reset every piece of state, with no
                    // exceptions to remember -- the CMD_RESYNC doctrine.
                    lines_seen  <= {6'd0, y};
                    frame_start <= 1'b1;
                    y <= 10'd0; x <= 10'd0; comp <= 2'd0; px_run <= 16'd0;
                end else if (s_de && !de_d) begin
                    // DE rising edge: this sample is R of pixel 0 by definition.
                    r_lat  <= s_d;
                    comp   <= 2'd1;
                    x      <= 10'd0;
                    px_run <= 16'd0;
                end else if (s_de) begin
                    case (comp)
                        2'd0: begin r_lat <= s_d; comp <= 2'd1; end
                        2'd1: begin g_lat <= s_d; comp <= 2'd2; end
                        default: begin
                            pix       <= {r_lat[7:3], g_lat[7:2], s_d[7:3]};
                            pix_x     <= x;
                            pix_y     <= y;
                            pix_valid <= (x < MAX_X[9:0]) && (y < MAX_Y[9:0]);
                            x         <= x + 10'd1;
                            px_run    <= px_run + 16'd1;
                            comp      <= 2'd0;
                        end
                    endcase
                end else if (!s_de && de_d) begin
                    // DE fell: a line ended.
                    px_in_line <= px_run;
                    y          <= y + 10'd1;
                    comp       <= 2'd0;
                end
            end
        end
    end
endmodule
`default_nettype wire
