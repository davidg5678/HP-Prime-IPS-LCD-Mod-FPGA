`timescale 1ns/1ps
`default_nettype none
//
// Synthetic serial-RGB source: the MOCK half of Phase 1's mock/real mux.
//
// Models the interface the HP Prime's SoC is believed to drive into its
// ILI9322-family controller (see docs/architecture.md): a DOTCLK, active-low
// HSYNC and VSYNC, active-high DE, and an 8-bit bus carrying R, G and B bytes
// time-multiplexed -- THREE DOTCLKs per pixel, not one. It is not a serial
// link in the one-wire sense.
//
// This generator exists so that trigger logic, buffer depth, sample packing
// and host-side decoding are all validatable against a known-correct pattern
// with no calculator, no probe wires and no human at a bench. Only the final
// "does it match the real thing" step needs hardware.
//
// TEST PATTERN, per active pixel at column x, row y:
//     R = x[7:0]
//     G = y[7:0]
//     B = x[7:0] ^ y[7:0]
// Chosen to be (a) reproducible in three lines of Python, so the host tool can
// assert on it exactly, and (b) an actual image -- horizontal ramp, vertical
// ramp, XOR plaid -- so Phase 2's decoder produces something whose correctness
// is obvious by eye as well as by assert. During blanking the bus is driven to
// 0x00, which also makes DE-gating errors visible as a shifted ramp.
//
// Outputs change on the DOTCLK FALLING edge, so they are stable across the
// rising edge where a receiver samples them.
//
// Defaults describe a deliberately small frame (32 px x 8 lines). Phase 1 is
// reverse-engineering an unknown bus, so there is nothing to be gained from
// mimicking a specific panel's timing; a small frame means a hardware capture
// holds several complete frames and a simulation can cover one in reasonable
// time. All of it is parameterised -- the testbench shrinks it further.
//
// Counters are a fixed 16 bits rather than $clog2-sized. Sizing them exactly
// bought nothing but a thicket of width casts around every comparison, and
// SystemVerilog-style casts are not safely portable across iverilog and
// GowinSynthesis. Sixteen bits costs a few dozen flip-flops on a part with
// 15552 of them.
//
module video_timing_gen #(
    parameter integer DOTCLK_DIV = 8,    // sample clocks per DOTCLK period; even, >= 2
    parameter integer H_TOTAL    = 120,  // DOTCLKs per line, including blanking
    parameter integer H_SYNC     = 6,    // HSYNC low width, DOTCLKs
    parameter integer H_START    = 18,   // first active DOTCLK within the line
    parameter integer H_ACTIVE   = 96,   // active DOTCLKs; MUST be a multiple of 3
    parameter integer V_TOTAL    = 10,   // lines per frame, including blanking
    parameter integer V_SYNC     = 1,    // VSYNC low width, lines
    parameter integer V_START    = 2,    // first active line within the frame
    parameter integer V_ACTIVE   = 8     // active lines
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       restart,   // 1-cycle pulse: return to the frame origin
    output reg        dotclk,
    output reg        hsync,     // active low
    output reg        vsync,     // active low
    output reg        de,        // active high
    output reg  [7:0] data
);
    localparam [15:0] HALF_M1    = (DOTCLK_DIV / 2) - 1;
    localparam [15:0] H_TOTAL_M1 = H_TOTAL - 1;
    localparam [15:0] H_SYNC_W   = H_SYNC;
    localparam [15:0] H_START_W  = H_START;
    localparam [15:0] H_END_W    = H_START + H_ACTIVE;
    localparam [15:0] V_TOTAL_M1 = V_TOTAL - 1;
    localparam [15:0] V_SYNC_W   = V_SYNC;
    localparam [15:0] V_START_W  = V_START;
    localparam [15:0] V_END_W    = V_START + V_ACTIVE;

    reg [15:0] div_cnt;
    reg [15:0] h_cnt;
    reg [15:0] v_cnt;
    reg [1:0]  comp;    // 0 = R, 1 = G, 2 = B
    reg [7:0]  x;       // pixel column; wraps at 256, which is what the pattern wants

    // One tick per DOTCLK half period; state advances on the falling edge.
    wire tick = (div_cnt == HALF_M1);
    wire fall = tick && dotclk;

    wire        h_wrap = (h_cnt == H_TOTAL_M1);
    wire [15:0] h_next = h_wrap ? 16'd0 : h_cnt + 16'd1;
    wire        v_wrap = (v_cnt == V_TOTAL_M1);
    wire [15:0] v_next = !h_wrap ? v_cnt : (v_wrap ? 16'd0 : v_cnt + 16'd1);

    wire h_act_next = (h_next >= H_START_W) && (h_next < H_END_W);
    wire v_act_next = (v_next >= V_START_W) && (v_next < V_END_W);
    wire de_next    = h_act_next && v_act_next;

    // y is a pure function of the line counter, so it needs no state of its
    // own. x does, because deriving it from h_cnt would mean dividing by 3.
    wire [15:0] y_next16 = v_next - V_START_W;
    wire [7:0]  y_next   = y_next16[7:0];

    // Start of an active run: reset the component phase and the pixel column.
    wire       de_rise    = de_next && !de;
    wire [1:0] comp_next  = de_rise ? 2'd0 : ((comp == 2'd2) ? 2'd0 : comp + 2'd1);
    wire [7:0] x_next     = de_rise ? 8'd0 : ((comp == 2'd2) ? x + 8'd1 : x);

    reg [7:0] data_next;
    always @(*) begin
        if (!de_next) data_next = 8'h00;
        else case (comp_next)
            2'd0:     data_next = x_next;
            2'd1:     data_next = y_next;
            default:  data_next = x_next ^ y_next;
        endcase
    end

    // The reset and restart branches assign identical values, and collapsing
    // them into `if (!rst_n || restart)` is very tempting. Do not: in a block
    // sensitive to `posedge clk or negedge rst_n`, the first branch must test
    // the ASYNCHRONOUS signal alone. OR-ing a synchronous condition into it
    // describes a flip-flop with two edge-sensitive resets, which no hardware
    // has. GowinSynthesis inferred something regardless and iverilog simulated
    // it without complaint; only yosys said so, with
    //   ERROR: Multiple edge sensitive events found for this signal!
    // -- which is the entire argument for keeping `make build-oss` in the loop.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 16'd0;
            dotclk  <= 1'b0;
            h_cnt   <= 16'd0;
            v_cnt   <= 16'd0;
            comp    <= 2'd0;
            x       <= 8'd0;
            hsync   <= 1'b1;
            vsync   <= 1'b1;
            de      <= 1'b0;
            data    <= 8'h00;
        end else if (restart) begin
            // Same doctrine as CMD_RESYNC in bringup_selftest: restarting the
            // source means every piece of source state, with no exceptions to
            // remember. A capture armed just after a restart must see the frame
            // origin, not wherever the free-running counters happened to be.
            div_cnt <= 16'd0;
            dotclk  <= 1'b0;
            h_cnt   <= 16'd0;
            v_cnt   <= 16'd0;
            comp    <= 2'd0;
            x       <= 8'd0;
            hsync   <= 1'b1;
            vsync   <= 1'b1;
            de      <= 1'b0;
            data    <= 8'h00;
        end else begin
            if (tick) begin
                div_cnt <= 16'd0;
                dotclk  <= ~dotclk;
            end else begin
                div_cnt <= div_cnt + 16'd1;
            end

            if (fall) begin
                h_cnt <= h_next;
                v_cnt <= v_next;
                hsync <= ~(h_next < H_SYNC_W);
                vsync <= ~(v_next < V_SYNC_W);
                de    <= de_next;
                data  <= data_next;
                if (de_next) begin
                    comp <= comp_next;
                    x    <= x_next;
                end else begin
                    comp <= 2'd0;
                    x    <= 8'd0;
                end
            end
        end
    end
endmodule
`default_nettype wire
