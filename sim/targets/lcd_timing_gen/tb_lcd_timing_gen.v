`timescale 1ns/1ps
`default_nettype none
//
// Unit testbench for src/common/lcd_timing_gen.v, at the REAL datasheet
// numbers -- 371 DCLK lines, 260 line frames, 6 MHz.
//
// Everything asserted here is read off the DUT's OUTPUT PINS, from the panel's
// point of view: intervals are counted in DCLK RISING EDGES between HSYNC
// falling edges, and in HSYNC falling edges between VSYNC falling edges,
// because those are the units the datasheet's AC table uses. Nothing here looks
// at hc, vc or ph inside the DUT. That distinction is the point --
// docs/verification.md's "assert on values recovered from the design, not on
// the constants you believe you set". A testbench that read the internal
// counters would agree with the parameters by construction and would keep
// agreeing if the output registers or the DE gating were wrong.
//
// Sub-DCLK quantities (period, duty, setup, hold) are measured in $realtime
// nanoseconds instead, and asserted against the datasheet's nanosecond specs.
//
// EXPECTED (docs/AFY320240A0-3.5INTH-C2-spec.pdf p.10, typical column):
//     Th 371   Thbp 43   Thdisp 320   Thfp 8   Thw 4     DCLK
//     Tv 260   Tvbp 12   Tvdisp 240   Tvfp 8   Tvw 4     HSYNC
//     Fclk 6 MHz, Tclk 167 ns, duty 40-60%
//     Tdsu/Tdhd/Thst/Thhd/Tvst/Tvhd/Tdest/Tdehd all 12 ns min
//
module tb_lcd_timing_gen;
    localparam real CLK_NS   = 9.259259;   // 108 MHz
    localparam real TCLK_NS  = 166.6667;   // 18 x CLK_NS, the 6 MHz DCLK period
    localparam real TOL_NS   = 0.5;
    localparam real SPEC_NS  = 12.0;       // every setup/hold min in the table

    // What the AC table says, in the units the AC table uses.
    localparam integer EXP_TH     = 371, EXP_THBP = 43, EXP_THDISP = 320,
                       EXP_THFP   = 8,   EXP_THW  = 4;
    localparam integer EXP_TV     = 260, EXP_TVBP = 12, EXP_TVDISP = 240,
                       EXP_TVFP   = 8,   EXP_TVW  = 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    wire       dclk, hsync_n, vsync_n, de, tick, nxt_de, frame_tick;
    wire [9:0] nxt_x, nxt_y;

    lcd_timing_gen u_dut (
        .clk(clk), .rst_n(rst_n), .restart(1'b0),
        .dclk(dclk), .hsync_n(hsync_n), .vsync_n(vsync_n), .de(de),
        .tick(tick), .nxt_de(nxt_de), .nxt_x(nxt_x), .nxt_y(nxt_y),
        .frame_tick(frame_tick)
    );

    integer errors = 0;
    task fail(input [1023:0] msg);
        begin
            $display("FAIL: %0s", msg);
            $fatal(1);
        end
    endtask

    // =======================================================================
    // Sub-DCLK measurements, in nanoseconds, straight off the pins.
    // =======================================================================
    real t_ck_rise = -1.0, t_ck_fall = -1.0;
    real min_period = 1.0e9, max_period = -1.0;
    real min_high   = 1.0e9, max_high   = -1.0;
    integer periods_seen = 0;

    always @(posedge dclk) begin
        if (t_ck_rise >= 0.0) begin
            if ($realtime - t_ck_rise < min_period) min_period = $realtime - t_ck_rise;
            if ($realtime - t_ck_rise > max_period) max_period = $realtime - t_ck_rise;
            periods_seen = periods_seen + 1;
        end
        t_ck_rise = $realtime;
    end
    always @(negedge dclk) begin
        if (t_ck_rise >= 0.0) begin
            if ($realtime - t_ck_rise < min_high) min_high = $realtime - t_ck_rise;
            if ($realtime - t_ck_rise > max_high) max_high = $realtime - t_ck_rise;
        end
        t_ck_fall = $realtime;
    end

    // Setup and hold of EVERY panel-facing signal against BOTH DCLK edges.
    //
    // This is the check that justifies the quarter-period phase shift in the
    // DUT. The datasheet labels DCLK "Negative Polarity" but the figures are
    // low-resolution scans and the panel's SPI (where DPOL lives) is unreachable
    // because the board grounds CS -- so the design must be correct on EITHER
    // edge. Measuring both, and taking the worst, is what turns that claim into
    // a number. If someone later "simplifies" the phase back to a conventional
    // change-on-one-edge scheme, one of these two goes to ~0 and this fails.
    real t_last_change = -1.0;
    real t_last_edge   = -1.0;
    real min_setup = 1.0e9, min_hold = 1.0e9;
    reg  measuring = 1'b0;

    always @(hsync_n or vsync_n or de or nxt_de) begin
        if (measuring) begin
            if (t_last_edge >= 0.0 && ($realtime - t_last_edge) < min_hold)
                min_hold = $realtime - t_last_edge;
        end
        t_last_change = $realtime;
    end

    always @(posedge dclk or negedge dclk) begin
        if (measuring && t_last_change >= 0.0) begin
            if (($realtime - t_last_change) < min_setup)
                min_setup = $realtime - t_last_change;
        end
        t_last_edge = $realtime;
    end

    // =======================================================================
    // Interval measurements, sampled the way the panel samples: at the DCLK
    // rising edge. Sampling here rather than on @(negedge hsync_n) also removes
    // a real simulation hazard -- HSYNC and VSYNC fall at the SAME instant at
    // the frame origin, so two separate edge-triggered blocks would race.
    // =======================================================================
    reg  hs_d = 1'b0, vs_d = 1'b0, de_d = 1'b0;
    integer h_pos = 0, v_pos = 0;

    integer m_th = -1, m_thbp = -1, m_thdisp = -1, m_thfp = -1, m_thw = -1;
    integer m_tv = -1, m_tvbp = -1, m_tvdisp = -1, m_tvfp = -1, m_tvw = -1;
    integer de_start_pos = -1, de_end_pos = -1;
    integer v_de_start = -1, v_de_end = -1;
    integer lines_done = 0, frames_done = 0;
    integer line_active_px = 0;
    integer bad_lines = 0;      // active lines whose pixel count != 320

    // Frozen copies of the first fully-measured frame, so late frames cannot
    // overwrite the values the final checks read.
    integer f_th = -1, f_thbp = -1, f_thdisp = -1, f_thfp = -1, f_thw = -1;
    integer f_tv = -1, f_tvbp = -1, f_tvdisp = -1, f_tvfp = -1, f_tvw = -1;

    always @(posedge dclk) begin
        // ---- horizontal, counted in DCLKs
        if (!hsync_n && hs_d) begin
            // HSYNC fell during this DCLK: a line boundary.
            if (measuring && h_pos > 0) begin
                m_th = h_pos + 1;
                if (de_start_pos >= 0 && de_end_pos >= 0) begin
                    m_thbp   = de_start_pos;
                    m_thdisp = de_end_pos - de_start_pos;
                    m_thfp   = (h_pos + 1) - de_end_pos;
                    if (m_thdisp != EXP_THDISP) bad_lines = bad_lines + 1;
                end
            end

            // ---- vertical, counted in lines
            if (measuring) begin
                if (line_active_px > 0) begin
                    if (v_de_start < 0) v_de_start = v_pos;
                    v_de_end = v_pos + 1;
                end
                lines_done = lines_done + 1;
            end

            if (!vsync_n && vs_d) begin
                // VSYNC fell in the same DCLK: a frame boundary. Nested, not a
                // separate branch -- see the comment above about the race.
                if (measuring && v_pos > 0) begin
                    m_tv     = v_pos + 1;
                    m_tvbp   = v_de_start;
                    m_tvdisp = v_de_end - v_de_start;
                    m_tvfp   = (v_pos + 1) - v_de_end;
                    if (frames_done == 0) begin
                        f_th   = m_th;   f_thbp   = m_thbp;   f_thdisp = m_thdisp;
                        f_thfp = m_thfp; f_thw    = m_thw;
                        f_tv   = m_tv;   f_tvbp   = m_tvbp;   f_tvdisp = m_tvdisp;
                        f_tvfp = m_tvfp; f_tvw    = m_tvw;
                    end
                    frames_done = frames_done + 1;
                end
                v_pos      = 0;
                v_de_start = -1;
                v_de_end   = -1;
                measuring  = 1'b1;   // from the first frame origin onwards
            end else begin
                v_pos = v_pos + 1;
            end

            h_pos        = 0;
            de_start_pos = -1;
            de_end_pos   = -1;
            line_active_px = 0;
        end else begin
            h_pos = h_pos + 1;
        end

        // HSYNC pulse width, in DCLKs, measured at its rising edge.
        if (hsync_n && !hs_d && measuring) m_thw = h_pos;

        // DE edges, in DCLK positions within the line.
        if (de && !de_d) de_start_pos = h_pos;
        if (!de && de_d) de_end_pos   = h_pos;
        if (de) line_active_px = line_active_px + 1;

        // VSYNC pulse width, in lines.
        if (vsync_n && !vs_d && measuring) m_tvw = v_pos;

        hs_d <= hsync_n;
        vs_d <= vsync_n;
        de_d <= de;
    end

    task chk_i(input [1023:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %0d, expected %0d", what, got, exp);
                errors = errors + 1;
            end else begin
                $display("  ok  %0s = %0d", what, got);
            end
        end
    endtask

    task chk_r(input [1023:0] what, input real got, input real lo, input real hi);
        begin
            if (got < lo || got > hi) begin
                $display("FAIL: %0s = %0.3f ns, expected %0.3f..%0.3f", what, got, lo, hi);
                errors = errors + 1;
            end else begin
                $display("  ok  %0s = %0.3f ns", what, got);
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;

        // Two complete frames after the first observed frame origin.
        wait (frames_done >= 2);
        @(posedge clk);

        $display("--- DCLK, measured in ns off the pin ---");
        chk_r("DCLK period", min_period, TCLK_NS - TOL_NS, TCLK_NS + TOL_NS);
        chk_r("DCLK period (max)", max_period, TCLK_NS - TOL_NS, TCLK_NS + TOL_NS);
        // 40-60% duty per the AC table; the design targets exactly 50%.
        chk_r("DCLK high time", min_high, TCLK_NS*0.40, TCLK_NS*0.60);
        chk_r("DCLK high time (max)", max_high, TCLK_NS*0.40, TCLK_NS*0.60);
        if (periods_seen < 1000) begin
            $display("FAIL: only %0d DCLK periods observed -- the clock is not running",
                     periods_seen);
            errors = errors + 1;
        end

        $display("--- setup/hold against BOTH DCLK edges (spec: %0.1f ns min) ---", SPEC_NS);
        chk_r("worst setup", min_setup, SPEC_NS, 1.0e9);
        chk_r("worst hold",  min_hold,  SPEC_NS, 1.0e9);

        $display("--- horizontal, in DCLKs ---");
        chk_i("Th     (line period)",  f_th,     EXP_TH);
        chk_i("Thbp   (back porch)",   f_thbp,   EXP_THBP);
        chk_i("Thdisp (active)",       f_thdisp, EXP_THDISP);
        chk_i("Thfp   (front porch)",  f_thfp,   EXP_THFP);
        chk_i("Thw    (sync width)",   f_thw,    EXP_THW);
        chk_i("lines with != 320 active DCLKs", bad_lines, 0);

        $display("--- vertical, in lines ---");
        chk_i("Tv     (frame period)", f_tv,     EXP_TV);
        chk_i("Tvbp   (back porch)",   f_tvbp,   EXP_TVBP);
        chk_i("Tvdisp (active)",       f_tvdisp, EXP_TVDISP);
        chk_i("Tvfp   (front porch)",  f_tvfp,   EXP_TVFP);
        chk_i("Tvw    (sync width)",   f_tvw,    EXP_TVW);

        // The parts must close with no residual, the same self-consistency
        // check docs/prime_lcd_protocol.md applies to the Prime's own timing.
        if (f_thbp + f_thdisp + f_thfp !== f_th) begin
            $display("FAIL: %0d + %0d + %0d = %0d, but Th = %0d",
                     f_thbp, f_thdisp, f_thfp, f_thbp+f_thdisp+f_thfp, f_th);
            errors = errors + 1;
        end
        if (f_tvbp + f_tvdisp + f_tvfp !== f_tv) begin
            $display("FAIL: %0d + %0d + %0d = %0d, but Tv = %0d",
                     f_tvbp, f_tvdisp, f_tvfp, f_tvbp+f_tvdisp+f_tvfp, f_tv);
            errors = errors + 1;
        end
        // The sync pulse must be INSIDE the back porch, not adjacent to it.
        // This is the reading that makes the AC table's columns sum, and
        // getting it backwards puts the image 4 pixels off with no other
        // symptom. See the header of src/common/lcd_timing_gen.v.
        if (f_thw >= f_thbp) begin
            $display("FAIL: Thw %0d is not nested inside Thbp %0d", f_thw, f_thbp);
            errors = errors + 1;
        end
        if (f_tvw >= f_tvbp) begin
            $display("FAIL: Tvw %0d is not nested inside Tvbp %0d", f_tvw, f_tvbp);
            errors = errors + 1;
        end

        if (errors != 0) begin
            $display("FAIL: %0d timing checks did not match the datasheet", errors);
            $fatal(1);
        end

        $display("PASS: lcd_timing_gen matches the AFY320240A0 AC table -- Th=%0d (%0d+%0d+%0d), Tv=%0d (%0d+%0d+%0d), DCLK %0.3f ns, worst setup %0.1f ns / hold %0.1f ns against a 12 ns spec",
                 f_th, f_thbp, f_thdisp, f_thfp, f_tv, f_tvbp, f_tvdisp, f_tvfp,
                 min_period, min_setup, min_hold);
        $finish;
    end

    // Watchdog: three frames at 6 MHz is ~48 ms. 80 ms is comfortably past two.
    initial begin
        #80_000_000;
        $display("FAIL: watchdog -- only %0d frames and %0d lines observed",
                 frames_done, lines_done);
        $fatal(1);
    end
endmodule
`default_nettype wire
