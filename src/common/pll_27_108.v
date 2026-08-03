`timescale 1ns/1ps
`default_nettype none
//
// 27 MHz -> 108 MHz clock generator, wrapping the Gowin `rPLL` hard macro.
//
// WHY A PLL AT ALL (this is not just about going faster):
//
// Pin 4's Function column in impl/pnr/project.rpt.txt reads `LPLL1_T_in` -- it
// is the dedicated reference input of the left PLL, NOT one of the five
// GCLK_PINs. A design that drives logic straight from pin 4 reaches the PRIMARY
// global clock network through generic routing, which is what
//   WARN (PR1014) Generic routing resource will be used to clock signal ...
// has been telling us since proto-phase-1. Feeding pin 4 into the rPLL is that
// pin's designed purpose, and it does fix the thing that actually mattered:
// the report's Global Clock Signals table now shows the 108 MHz `clk_s` on
// PRIMARY across all four quadrants (TR TL BR BL), where before the system
// clock reached logic through generic routing.
//
// MEASURED, not assumed: PR1014 does NOT disappear. It now names `clk_d`, the
// 27 MHz reference hop from pin 4 into the adjacent PLL -- a short, local,
// low-frequency net with exactly one load and, per the timing report, no
// clk27-domain registers at all ("No timing paths to get frequency of clk27").
// So the warning survives but its subject changed from the design's system
// clock to a net that has nothing timing-critical on it. An earlier version of
// this comment predicted the warning would clear outright; it did not, and
// saying so is cheaper than the next person re-deriving it.
//
// WHY 108 MHz SPECIFICALLY:
//
//   * 108 = 27 * 4 exactly, so the PLL ratio is trivial and jitter-free.
//   * 108 MHz / 1_000_000 baud = DIV 108 exactly -- zero UART division error,
//     preserving the property that made 1 Mbaud work at 27 MHz (DIV 27). The
//     whole design therefore stays in ONE clock domain: capture, control and
//     UART all run at 108 MHz and the only clock-domain crossing in the design
//     is the probe pins themselves (handled by sync2).
//   * 9.26 ns sample resolution. Against an expected DOTCLK in the 5-30 MHz
//     range that is 3.6-21 samples per bit period -- comfortable oversampling
//     for a signal whose rate is not yet known.
//
// rPLL MATHS (GW2A-18 family):
//   CLKOUT = CLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 * 4 / 1 = 108 MHz
//   VCO    = CLKOUT * ODIV_SEL                    = 108 * 8     = 864 MHz
// The VCO must land in 400-1200 MHz; 864 is comfortably mid-band.
//
// `rPLL` is a hard macro: Gowin's synthesiser knows it intrinsically, so no
// source file backs it in the synthesis flow. iverilog does not, so
// sim/models/rPLL.v supplies a behavioural model that is listed ONLY in the
// sim files.txt. That keeps this wrapper -- the actual RTL -- byte-identical
// between simulation and synthesis, with no `ifdef` seam through the design.
//
module pll_27_108 (
    input  wire clkin,    // 27 MHz, pin 4
    output wire clkout,   // 108 MHz
    output wire lock
);
    rPLL #(
        .FCLKIN          ("27"),
        .DEVICE          ("GW2AR-18C"),
        .IDIV_SEL        (0),        // /1
        .FBDIV_SEL       (3),        // x4
        .ODIV_SEL        (8),        // VCO = 864 MHz
        .DYN_IDIV_SEL    ("false"),
        .DYN_FBDIV_SEL   ("false"),
        .DYN_ODIV_SEL    ("false"),
        .PSDA_SEL        ("0000"),
        .DYN_DA_EN       ("false"),
        .DUTYDA_SEL      ("1000"),
        .CLKOUT_FT_DIR   (1'b1),
        .CLKOUTP_FT_DIR  (1'b1),
        .CLKOUT_DLY_STEP (0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL       ("internal"),
        .CLKOUT_BYPASS   ("false"),
        .CLKOUTP_BYPASS  ("false"),
        .CLKOUTD_BYPASS  ("false"),
        .DYN_SDIV_SEL    (2),
        .CLKOUTD_SRC     ("CLKOUT"),
        .CLKOUTD3_SRC    ("CLKOUT")
    ) u_rpll (
        .CLKIN    (clkin),
        .CLKFB    (1'b0),
        .RESET    (1'b0),
        .RESET_P  (1'b0),
        .FBDSEL   (6'b000000),
        .IDSEL    (6'b000000),
        .ODSEL    (6'b000000),
        .PSDA     (4'b0000),
        .DUTYDA   (4'b0000),
        .FDLY     (4'b0000),
        .CLKOUT   (clkout),
        .LOCK     (lock),
        .CLKOUTP  (),
        .CLKOUTD  (),
        .CLKOUTD3 ()
    );
endmodule
`default_nettype wire
