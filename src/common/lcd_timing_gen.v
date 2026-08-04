`timescale 1ns/1ps
`default_nettype none
//
// Phase 3: panel-legal RGB timing generator for the Orient Display
// AFY320240A0-3.5INTH-C2 (ST7272A), driven from the board's 40-pin FPC.
//
// This is NOT the Prime's timing and cannot be. Every temporal figure of the
// Prime's bus is illegal for this panel -- DOTCLK 13.289 MHz against a 5-8 MHz
// spec, line 102.4 us against 55-65 us, frame 37.70 Hz against ~58-68 Hz. Only
// the 320x240 resolution matches. See docs/panel_afy320240a0.md. Phase 4 must
// therefore retime through a frame buffer, and this module is the thing it
// retimes ONTO.
//
// ---------------------------------------------------------------------------
// DEFAULTS ARE THE DATASHEET'S TYPICAL COLUMN, READ OFF THE AC TABLE DIRECTLY
// ---------------------------------------------------------------------------
// docs/AFY320240A0-3.5INTH-C2-spec.pdf p.10, "Parallel 24-bit RGB Input Timing
// Table". The table is an IMAGE, so these were read visually rather than
// extracted -- min / typ / max:
//
//   Fclk    5 / 6 / 8 MHz          Tclk   125 / 167 / 200 ns
//   Th    325 / 371 / 438 DCLK     Thdisp        320 DCLK
//   Thbp    3 /  43 /  43 DCLK     Thfp     2 /  8 / 75 DCLK
//   Thw     2 /   4 /  43 DCLK
//   Tv    244 / 260 / 289 HSYNC    Tvdisp        240 HSYNC
//   Tvbp    2 /  12 /  12 HSYNC    Tvfp     2 /  8 / 37 HSYNC
//   Tvw     2 /   4 /  12 HSYNC
//
//   43 + 320 +  8 = 371  = Th typ   ok
//   12 + 240 +  8 = 260  = Tv typ   ok
//
// The parts close exactly, which is the reading under which BACK PORCH INCLUDES
// THE SYNC PULSE. The SYNC-mode diagram on p.11 confirms it directly: Thbp is
// drawn from the HSYNC falling edge to the start of the display period, with
// Thw nested inside it. Get this backwards and the image sits 4 pixels right.
//
// Thbp=43 and Tvbp=12 are NOT free choices. The datasheet note reads:
//     "It is necessary to keep Tvbp=12 and Thbp=43 in sync mode. DE mode is
//      unnecessary to keep it."
// and in SYNC mode those porches come from the H_BLANKING/V_BLANKING registers,
// which are reachable only over the 3-wire SPI -- and the board grounds the
// panel's CS pin, so no serial command can ever latch (a command completes on
// the RISING edge of CS, which never arrives). We are permanently on the
// power-on default register set. This module therefore emits the exact default
// porches AND a correct DE, so the panel is driven legally whether it is in
// SYNC, SYNC-DE or DE mode. That costs nothing and removes a whole failure mode
// from first light.
//
// ---------------------------------------------------------------------------
// WHY DCLK IS PHASE-SHIFTED A QUARTER PERIOD (the one real design decision)
// ---------------------------------------------------------------------------
// Every figure in the datasheet labels the clock "DCLK (Negative Polarity)",
// but the figures are low-resolution scans and which edge the panel actually
// latches on cannot be read off them with confidence. Normally you would set
// DPOL over the SPI -- which, per above, is unreachable.
//
// The obvious approach (change data on one edge, let the panel sample the
// other) is a coin flip: if the guess is wrong, data changes AT the sampling
// edge and every pixel is garbage. Phase 1 already paid for exactly this class
// of mistake in the other direction -- see "Two traps when decoding this bus"
// in docs/prime_lcd_protocol.md, where latching midway between DOTCLK edges
// landed on the data transition and produced output that looked like
// anti-aliasing rather than like a bug.
//
// So instead: data changes at phase 0, and DCLK's two edges are placed at
// phases 4 and 13 of an 18-cycle period. Neither edge is anywhere near a data
// transition:
//
//   phase   0    4              13        18/0
//   data  --X----------------------------X------   changes at phase 0
//   dclk  ~~~~~~\________________/~~~~~~~~~~~~~~
//               |                |
//        setup 4 cyc = 37.0 ns   setup 13 cyc = 120.4 ns
//        hold 14 cyc = 129.6 ns  hold  5 cyc =  46.3 ns
//
// The panel needs 12 ns of setup and 12 ns of hold (Tdsu/Tdhd/Thst/Thhd/
// Tvst/Tvhd/Tdest/Tdehd, all 12 ns min). The WORST of the four numbers above is
// 37.0 ns -- 3.1x the requirement -- so the design is correct on either
// polarity, and DCLK_FALL/DCLK_RISE stay as parameters if hardware ever
// disagrees. Duty is exactly 50% (9 cycles high, 9 low) against a 40-60% spec.
//
// This is only affordable because 6 MHz is slow: one DCLK is 18 system clocks,
// so quarter-period granularity is free. It would not work at 108 MHz.
//
// ---------------------------------------------------------------------------
// PIXEL SOURCE INTERFACE
// ---------------------------------------------------------------------------
// `nxt_x`/`nxt_y`/`nxt_de` describe the pixel period that BEGINS at the next
// `tick`, and are stable for a full DCLK period (166 ns / 18 system clocks)
// before that. A combinational source (src/common/test_pattern.v) therefore has
// an entire DCLK to settle, and Phase 4's SDRAM-backed line buffer has an
// entire DCLK of read latency to hide. That lookahead is the whole reason the
// interface is shaped this way rather than handing out the current coordinates.
//
// Counters are a fixed 16 bits rather than $clog2-sized, for the same reason
// video_timing_gen gives: exact sizing buys nothing but a thicket of width
// casts, and SystemVerilog-style casts are not safely portable across iverilog
// and GowinSynthesis.
//
module lcd_timing_gen #(
    // Clock division. 108 MHz / 18 = 6.000 MHz exactly, the datasheet typical.
    parameter integer CLK_DIV   = 18,
    parameter integer DCLK_FALL = 4,    // phase at which DCLK goes low
    parameter integer DCLK_RISE = 13,   // phase at which DCLK goes high

    // Horizontal, in DCLKs. H_BACK includes H_SYNC (see above).
    parameter integer H_SYNC   = 4,     // Thw
    parameter integer H_BACK   = 43,    // Thbp  -- fixed by the default registers
    parameter integer H_ACTIVE = 320,   // Thdisp
    parameter integer H_FRONT  = 8,     // Thfp

    // Vertical, in lines. V_BACK includes V_SYNC.
    parameter integer V_SYNC   = 4,     // Tvw
    parameter integer V_BACK   = 12,    // Tvbp  -- fixed by the default registers
    parameter integer V_ACTIVE = 240,   // Tvdisp
    parameter integer V_FRONT  = 8      // Tvfp
) (
    input  wire        clk,        // 108 MHz system clock
    input  wire        rst_n,
    input  wire        restart,    // pulse: return to the frame origin at the next tick

    // Panel-facing, all registered, all changing together at phase 0.
    output wire        dclk,
    output reg         hsync_n,    // active low
    output reg         vsync_n,    // active low
    output reg         de,         // active high

    // Pixel source interface -- see above.
    output wire        tick,       // 1 cycle, at phase CLK_DIV-1: outputs update next cycle
    output wire        nxt_de,
    output wire [9:0]  nxt_x,      // 0..H_ACTIVE-1, meaningful only when nxt_de
    output wire [9:0]  nxt_y,      // 0..V_ACTIVE-1, meaningful only when nxt_de

    output reg         frame_tick  // 1 cycle, at the tick that starts a new frame
);
    localparam [15:0] DIV_M1    = CLK_DIV - 1;
    localparam [15:0] FALL_M1   = DCLK_FALL - 1;
    localparam [15:0] RISE_M1   = DCLK_RISE - 1;
    localparam [15:0] H_TOTAL_M1= (H_BACK + H_ACTIVE + H_FRONT) - 1;
    localparam [15:0] H_SYNC_W  = H_SYNC;
    localparam [15:0] H_BACK_W  = H_BACK;
    localparam [15:0] H_END_W   = H_BACK + H_ACTIVE;
    localparam [15:0] V_TOTAL_M1= (V_BACK + V_ACTIVE + V_FRONT) - 1;
    localparam [15:0] V_SYNC_W  = V_SYNC;
    localparam [15:0] V_BACK_W  = V_BACK;
    localparam [15:0] V_END_W   = V_BACK + V_ACTIVE;

    reg [15:0] hc;     // DCLK within the line, 0 at the HSYNC falling edge
    reg [15:0] vc;     // line within the frame, 0 at the VSYNC falling edge

    // -----------------------------------------------------------------------
    // THE DCLK PHASE GENERATOR FREE-RUNS FROM CONFIGURATION AND HAS NO RESET
    // -----------------------------------------------------------------------
    // This looks like exactly the mistake CLAUDE.md records under "give every
    // register a reset term" -- the heartbeat counter that kept blinking while
    // the design sat in reset, making the liveness LED true and useless at once.
    // It is the opposite case, and the reason is measurable.
    //
    // With ph held at 0 through reset, DCLK parks high for the whole reset
    // interval and the first period after release is stretched by its full
    // length. sim/targets/lcd_timing_gen measured 203.7 ns from a ten-cycle
    // testbench reset; the real power-on reset is 32768 cycles, so on hardware
    // that first period would be ~304 us. The AC table's Tclk maximum is 200 ns
    // (Fclk min 5 MHz), so a parked clock is an out-of-spec clock -- and a
    // panel's internal timing generator is derived from DCLK.
    //
    // Free-running instead makes DCLK metronomic from the moment the bitstream
    // loads. What moves is the anomaly's location: the frame-origin DCLK simply
    // lasts longer than one period while the video counters are held, so the
    // first LINE is long. A long blanking interval at power-on is ordinary; an
    // out-of-spec clock is not.
    //
    // The cost, stated plainly so nobody has to rediscover it: DCLK TOGGLING IS
    // NOT EVIDENCE THAT THE DESIGN IS OUT OF RESET. Nothing in this project uses
    // it as such -- lcd_panel_top's "frames are being emitted" LED and its
    // status report both key off the frame counter, which does require the video
    // counters to be running.
    reg [15:0] ph    = 16'd0;   // 0 .. CLK_DIV-1, position within one DCLK period
    reg        dclk_r = 1'b1;   // high at phase 0, per the diagram above
    assign dclk = dclk_r;

    // `tick` is the LOAD pulse, one cycle before the outputs change. A value
    // assigned when ph == CLK_DIV-1 appears on the pins during ph == 0, which
    // is what puts the data transition at phase 0 as documented above.
    assign tick = (ph == DIV_M1);

    always @(posedge clk) begin
        ph <= tick ? 16'd0 : ph + 16'd1;
        // DCLK edges, deliberately away from the phase-0 data transition.
        if (ph == FALL_M1) dclk_r <= 1'b0;
        if (ph == RISE_M1) dclk_r <= 1'b1;
    end

    // A restart is DEFERRED to the next tick rather than applied immediately.
    // Applying it the instant the pulse arrives would move every panel-facing
    // signal at an arbitrary phase -- possibly right at a DCLK edge, which is
    // the one thing the phase offset above exists to prevent. Deferring costs at
    // most 17 system clocks and keeps the guarantee unconditional.
    reg restart_q;
    wire do_origin = tick && (restart || restart_q);

    wire        h_wrap = (hc == H_TOTAL_M1);
    wire [15:0] h_next = h_wrap ? 16'd0 : hc + 16'd1;
    wire        v_wrap = (vc == V_TOTAL_M1);
    wire [15:0] v_next = !h_wrap ? vc : (v_wrap ? 16'd0 : vc + 16'd1);

    wire h_act_next = (h_next >= H_BACK_W) && (h_next < H_END_W);
    wire v_act_next = (v_next >= V_BACK_W) && (v_next < V_END_W);

    wire [15:0] x_next16 = h_next - H_BACK_W;
    wire [15:0] y_next16 = v_next - V_BACK_W;

    assign nxt_de = h_act_next && v_act_next;
    assign nxt_x  = x_next16[9:0];
    assign nxt_y  = y_next16[9:0];

    // Note there is no `else if (restart)` branch parallel to the reset branch
    // here, and that is deliberate beyond the deferral described above. In a
    // block sensitive to `posedge clk or negedge rst_n`, the first branch must
    // test the ASYNCHRONOUS signal alone; OR-ing a synchronous condition into it
    // describes a flip-flop with two edge-sensitive resets, which no hardware
    // has. GowinSynthesis infers something regardless and iverilog simulates it
    // without complaint -- only yosys objects, with
    //   ERROR: Multiple edge sensitive events found for this signal!
    // which is the entire argument for keeping `make build-oss` in the loop.
    // See the same note in src/common/video_timing_gen.v.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hc <= 16'd0; vc <= 16'd0;
            hsync_n <= 1'b0; vsync_n <= 1'b0; de <= 1'b0;
            frame_tick <= 1'b0; restart_q <= 1'b0;
        end else begin
            frame_tick <= 1'b0;

            // Hold the request until a tick can consume it. do_origin has
            // priority over restart: if a restart pulse lands ON a tick the
            // origin is applied in that same cycle, and latching the request as
            // well would apply it a SECOND time one DCLK later.
            if (do_origin)   restart_q <= 1'b0;
            else if (restart) restart_q <= 1'b1;

            if (do_origin) begin
                // Restarting the source means every piece of source state, with
                // no exceptions to remember -- the doctrine CMD_RESYNC
                // established in bringup_selftest_top.v.
                hc <= 16'd0; vc <= 16'd0;
                hsync_n <= 1'b0; vsync_n <= 1'b0; de <= 1'b0;
            end else if (tick) begin
                hc      <= h_next;
                vc      <= v_next;
                hsync_n <= ~(h_next < H_SYNC_W);
                vsync_n <= ~(v_next < V_SYNC_W);
                de      <= nxt_de;
                if (h_wrap && v_wrap) frame_tick <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
