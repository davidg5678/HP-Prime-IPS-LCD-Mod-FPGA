`timescale 1ns/1ps
//
// Behavioural model of the Gowin `rPLL` hard macro, for Icarus Verilog only.
//
// `rPLL` is a primitive the Gowin synthesiser knows intrinsically -- there is
// no source file for it in the vendor flow. iverilog has no such knowledge, so
// without this model src/common/pll_27_108.v would elaborate to a black box
// with a permanently-X output and every simulation of a PLL-based target would
// be meaningless.
//
// This file is listed ONLY in sim/targets/<t>/files.txt, never in
// src/targets/<t>/files.txt. That is the whole point: the synthesisable RTL
// stays byte-identical between the two flows, with no `ifdef` seam running
// through the design. (Contrast the mock/real convention in CLAUDE.md, which
// is about two DATA PATHS coexisting in one bitstream at runtime. This is a
// different thing -- one path, with a vendor primitive that only one of the
// two toolchains can elaborate.)
//
// The output frequency is derived by MEASURING the input clock period rather
// than parsing the FCLKIN string parameter. Measuring means the model cannot
// silently disagree with the testbench about what the reference clock actually
// is -- if the tb drives 27 MHz, the model produces exactly CLKIN * ratio off
// that, whatever FCLKIN claims.
//
// Not modelled (nothing in this project uses them): phase shift (PSDA/DUTYDA),
// dynamic divider reload (DYN_*), CLKOUTP/CLKOUTD/CLKOUTD3, or realistic lock
// behaviour beyond a fixed delay.
//
module rPLL #(
    parameter FCLKIN           = "100.0",
    parameter DEVICE           = "GW2A-18C",
    parameter integer IDIV_SEL = 0,
    parameter integer FBDIV_SEL= 0,
    parameter integer ODIV_SEL = 8,
    parameter DYN_IDIV_SEL     = "false",
    parameter DYN_FBDIV_SEL    = "false",
    parameter DYN_ODIV_SEL     = "false",
    parameter PSDA_SEL         = "0000",
    parameter DYN_DA_EN        = "false",
    parameter DUTYDA_SEL       = "1000",
    parameter CLKOUT_FT_DIR    = 1'b1,
    parameter CLKOUTP_FT_DIR   = 1'b1,
    parameter integer CLKOUT_DLY_STEP  = 0,
    parameter integer CLKOUTP_DLY_STEP = 0,
    parameter CLKFB_SEL        = "internal",
    parameter CLKOUT_BYPASS    = "false",
    parameter CLKOUTP_BYPASS   = "false",
    parameter CLKOUTD_BYPASS   = "false",
    parameter integer DYN_SDIV_SEL = 2,
    parameter CLKOUTD_SRC      = "CLKOUT",
    parameter CLKOUTD3_SRC     = "CLKOUT"
) (
    input  wire       CLKIN,
    input  wire       CLKFB,
    input  wire       RESET,
    input  wire       RESET_P,
    input  wire [5:0] FBDSEL,
    input  wire [5:0] IDSEL,
    input  wire [5:0] ODSEL,
    input  wire [3:0] PSDA,
    input  wire [3:0] DUTYDA,
    input  wire [3:0] FDLY,
    output wire       CLKOUT,
    output reg        LOCK,
    output wire       CLKOUTP,
    output wire       CLKOUTD,
    output wire       CLKOUTD3
);
    // Lock time of a real rPLL is tens of microseconds. 2 us is enough to make
    // reset-sequencing bugs (releasing reset before LOCK) visible in a
    // simulation without dominating its runtime.
    localparam real LOCK_DELAY_NS = 2000.0;

    real t_prev  = 0.0;
    real t_in    = 0.0;   // measured CLKIN period, ns
    real t_half  = 0.0;   // half period of the generated output, ns
    reg  clkout_r = 1'b0;
    integer edges = 0;

    // Measure the input period across two consecutive rising edges. The first
    // edge only establishes a reference, hence the `edges` guard -- using it
    // would compute a period counted from time 0.
    always @(posedge CLKIN) begin
        if (edges > 0) begin
            t_in  = $realtime - t_prev;
            t_half = (t_in * (IDIV_SEL + 1)) / ((FBDIV_SEL + 1) * 2.0);
        end
        t_prev = $realtime;
        edges  = edges + 1;
    end

    initial begin
        LOCK = 1'b0;
        clkout_r = 1'b0;
        // `always #(t_half)` with t_half still 0.0 would spin forever at time
        // zero, so wait for the measurement to land first.
        wait (t_half > 0.0);
        fork
            forever #(t_half) clkout_r = ~clkout_r;
            begin
                #(LOCK_DELAY_NS);
                LOCK = 1'b1;
            end
        join
    end

    assign CLKOUT   = clkout_r;
    assign CLKOUTP  = clkout_r;
    assign CLKOUTD  = 1'b0;
    assign CLKOUTD3 = 1'b0;
endmodule
