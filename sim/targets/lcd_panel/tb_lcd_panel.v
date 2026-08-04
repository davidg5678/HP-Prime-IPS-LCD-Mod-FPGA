`timescale 1ns/1ps
`default_nettype none
//
// Top-level testbench for src/targets/lcd_panel (Phase 3).
//
// sim/targets/lcd_timing_gen covers the AC-table timing in depth. This one
// covers everything BETWEEN the modules, which is where proto-phase-1 lost
// three sessions: it had a passing uart_tx<->uart_rx loopback the whole time
// while the top level had three bugs that made it permanently unable to work.
// See docs/verification.md.
//
// So the questions here are integration questions:
//
//   * Do pixels reach the pins with the right COORDINATES? A timing generator
//     with perfect porches still produces a shifted image if the pixel source
//     is fed the wrong coordinate or sampled a DCLK late. Checked by comparing
//     every one of the 76,800 active pixels in a frame against an oracle
//     written from test_pattern.v's documented spec, not copied from its code.
//   * Does the DE gating hold? Checked by asserting the bus is 0 outside DE.
//   * Does the command channel work end to end, over a real bit-banged UART at
//     1 Mbaud rather than by poking registers?
//   * Does the status report agree with what the testbench measured
//     independently off the same pins? This is the check that makes
//     `make lcd-hw` mean something -- the host script trusts those numbers.
//   * Does the backlight honour the datasheet's 250 ms T2 delay and then PWM at
//     the commanded duty?
//
// BL_DELAY_CYCLES is overridden to something a simulation can afford. The real
// default is separately asserted to be >= 250 ms via u_defaults below, so
// "shrunk for simulation" cannot quietly become "shrunk on hardware".
//
module tb_lcd_panel;
    localparam real CLK27_NS = 37.037037;   // 27 MHz at pin 4
    localparam real BIT_NS   = 1000.0;      // 1 Mbaud
    localparam real CLK_S_NS = 9.259259;    // 108 MHz after the PLL

    // ~46 us instead of 250 ms.
    localparam integer TB_BL_DELAY = 5000;
    localparam integer PWM_PERIOD_CYCLES = 422 * 256;
    localparam real    PWM_PERIOD_NS     = PWM_PERIOD_CYCLES * CLK_S_NS;

    localparam integer EXP_H_TOTAL = 371, EXP_H_ACTIVE = 320;
    localparam integer EXP_V_TOTAL = 260, EXP_V_ACTIVE = 240;
    localparam integer EXP_PIXELS  = EXP_H_ACTIVE * EXP_V_ACTIVE;   // 76,800

    localparam [7:0] CMD_RESET = 8'hAA, CMD_PATTERN = 8'h50,
                     CMD_BL    = 8'h42, CMD_STATUS  = 8'h53;

    reg clk = 1'b0;
    always #(CLK27_NS/2.0) clk = ~clk;

    reg  rx_line = 1'b1;      // host -> FPGA, idle high
    wire tx_line;             // FPGA -> host

    wire [4:0] lcd_r, lcd_b;
    wire [5:0] lcd_g;
    wire       lcd_ck, lcd_hs, lcd_vs, lcd_de, lcd_bl;
    wire [5:0] leds;

    lcd_panel_top #(.BL_DELAY_CYCLES(TB_BL_DELAY), .BL_DUTY_INIT(8'd64)) dut (
        .clk(clk), .uart_rx(rx_line), .uart_tx(tx_line),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .lcd_ck(lcd_ck), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_de(lcd_de),
        .lcd_bl(lcd_bl), .leds(leds)
    );

    // A second instance carrying the REAL defaults, deliberately never clocked
    // (clk tied low, so the rPLL model produces no events and this costs
    // nothing at runtime). It exists only so the checks at the end can read
    // lcd_panel_top's default parameters. Without it, overriding
    // BL_DELAY_CYCLES for simulation would leave the shipped value untested --
    // and a backlight that comes on 250 ms early is exactly the kind of thing
    // that works fine on the bench and damages a panel over months.
    wire [4:0] d_r, d_b;
    wire [5:0] d_g, d_leds;
    wire       d_ck, d_hs, d_vs, d_de, d_bl, d_tx;
    lcd_panel_top u_defaults (
        .clk(1'b0), .uart_rx(1'b1), .uart_tx(d_tx),
        .lcd_r(d_r), .lcd_g(d_g), .lcd_b(d_b),
        .lcd_ck(d_ck), .lcd_hs(d_hs), .lcd_vs(d_vs), .lcd_de(d_de),
        .lcd_bl(d_bl), .leds(d_leds)
    );

    integer errors = 0;
    task note_err(input [1023:0] msg);
        begin
            if (errors < 20) $display("FAIL: %0s", msg);
            errors = errors + 1;
        end
    endtask

    // =======================================================================
    // The oracle. Written from the pattern descriptions in the header of
    // src/common/test_pattern.v, in a different style and with different
    // expressions -- x < 40 chains rather than the RTL's, explicit modulo
    // rather than bit tests. Agreement is then evidence rather than tautology,
    // the same argument tb_frame_capture makes by using video_timing_gen as an
    // independent implementation of the Prime's protocol.
    // =======================================================================
    function [15:0] expect_rgb(input integer sel, input integer x, input integer y);
        integer r, g, b, bar;
        begin
            r = 0; g = 0; b = 0;
            case (sel)
                0: begin   // GRID
                    if (x == 0 || x == 319 || y == 0 || y == 239) begin
                        r = 31; g = 63; b = 31;
                    end else if (x == 160 || y == 120) begin
                        r = 31; g = 0;  b = 0;
                    end else if ((x % 32) == 0 || (y % 32) == 0) begin
                        r = 8;  g = 16; b = 8;
                    end
                end
                1: begin   // BARS: W Y C G M R B K, 40 px each
                    bar = x / 40;
                    r = (bar == 0 || bar == 1 || bar == 4 || bar == 5) ? 31 : 0;
                    g = (bar == 0 || bar == 1 || bar == 2 || bar == 3) ? 63 : 0;
                    b = (bar == 0 || bar == 2 || bar == 4 || bar == 6) ? 31 : 0;
                end
                2: begin   // RAMPS: 256-px ramps at x = 32..287, in three bands
                    if (x >= 32 && x < 288) begin
                        if      (y <  80) r = (x - 32) / 8;
                        else if (y < 160) g = (x - 32) / 4;
                        else              b = (x - 32) / 8;
                    end
                end
                3: begin   // PLAID: R = x, G = y, B = x^y
                    r = (x % 256) / 8;
                    g = (y % 256) / 4;
                    b = ((x ^ y) % 256) / 8;
                end
                4: begin r = 31; g = 63; b = 31; end          // WHITE
                5: begin r = 0;  g = 0;  b = 0;  end          // BLACK
                6: begin                                       // THIRDS
                    if      (y <  80) r = 31;
                    else if (y < 160) g = 63;
                    else              b = 31;
                end
                default: begin                                 // CHECKER
                    if (((x ^ y) % 2) == 1) begin r = 31; g = 63; b = 31; end
                end
            endcase
            expect_rgb = {r[4:0], g[5:0], b[4:0]};
        end
    endfunction

    // =======================================================================
    // Pixel and geometry capture, sampled at the DCLK rising edge -- the way
    // the panel samples, and deterministic where an @(negedge lcd_hs) block
    // would race the coincident VSYNC edge at the frame origin.
    // =======================================================================
    reg  hs_d = 1'b0, vs_d = 1'b0, de_d = 1'b0;
    integer x_pos = 0, y_pos = 0;
    integer frames = 0;
    integer px_this_frame = 0;
    integer lines_bad_len = 0;
    integer px_errors = 0, blank_errors = 0;
    integer px_checked = 0;
    integer check_sel = -1;          // -1 disables content checking
    integer frame_px_at_end = -1;    // pixels in the last completed frame

    integer ck_in_line = 0, lines_in_frame = 0;
    integer m_h_total = -1, m_v_total = -1;

    wire [15:0] got_rgb = {lcd_r, lcd_g, lcd_b};

    always @(posedge lcd_ck) begin
        // ---- frame boundary (VSYNC fell during this DCLK)
        if (!lcd_vs && vs_d) begin
            frame_px_at_end = px_this_frame;
            m_v_total  = lines_in_frame + 1;
            px_this_frame = 0;
            y_pos = 0;
            lines_in_frame = 0;
            frames = frames + 1;
        end else if (!lcd_hs && hs_d) begin
            lines_in_frame = lines_in_frame + 1;
        end

        // ---- line length, in DCLKs
        if (!lcd_hs && hs_d) begin
            m_h_total = ck_in_line + 1;
            ck_in_line = 0;
        end else begin
            ck_in_line = ck_in_line + 1;
        end

        // ---- pixels
        if (lcd_de) begin
            if (!de_d) x_pos = 0;
            if (check_sel >= 0 && y_pos < EXP_V_ACTIVE && x_pos < EXP_H_ACTIVE) begin
                px_checked = px_checked + 1;
                if (got_rgb !== expect_rgb(check_sel, x_pos, y_pos)) begin
                    if (px_errors < 8)
                        $display("FAIL: pixel (%0d,%0d) pat %0d: got %04h expected %04h",
                                 x_pos, y_pos, check_sel, got_rgb,
                                 expect_rgb(check_sel, x_pos, y_pos));
                    px_errors = px_errors + 1;
                end
            end
            x_pos = x_pos + 1;
            px_this_frame = px_this_frame + 1;
        end else begin
            // The bus must be driven to zero outside DE -- both because
            // lcd_panel_top says so and because a DE-gating bug otherwise shows
            // up as held-over pixels rather than as a visible fault.
            if (got_rgb !== 16'h0000) blank_errors = blank_errors + 1;
            if (de_d) begin
                if (x_pos != EXP_H_ACTIVE) lines_bad_len = lines_bad_len + 1;
                y_pos = y_pos + 1;
            end
        end

        hs_d <= lcd_hs;
        vs_d <= lcd_vs;
        de_d <= lcd_de;
    end

    // =======================================================================
    // Backlight duty accumulator
    // =======================================================================
    reg bl_high_early = 1'b0;

    // Measured by walking edges INSIDE the task, entirely sequentially.
    //
    // The first version used a separate `always @(lcd_bl)` accumulator gated by
    // a flag, with a fixed #(2 * PWM_PERIOD_NS) window. That window ends exactly
    // on a falling edge -- and whether the accumulator process or the task's
    // "stop measuring" assignment runs first at that instant is undefined in
    // Verilog. It consistently dropped one of the two high intervals and
    // reported precisely half the true duty, which is convincing enough to be
    // mistaken for a real /2 in the RTL. Bounding the window by counting edges
    // in the same process removes the cross-process ordering entirely.
    //
    // Assumes a duty strictly between 0 and 255 (there must be edges to walk);
    // the duty-0 case is checked by level instead.
    task measure_duty(output real duty);
        real t0, t_rise, t_high;
        integer n;
        begin
            @(negedge lcd_bl);
            t0 = $realtime;
            t_high = 0.0;
            for (n = 0; n < 2; n = n + 1) begin
                @(posedge lcd_bl); t_rise = $realtime;
                @(negedge lcd_bl); t_high = t_high + ($realtime - t_rise);
            end
            duty = t_high / ($realtime - t0);
        end
    endtask

    // =======================================================================
    // Bit-banged UART, at the real 1 Mbaud line rate
    // =======================================================================
    task uart_send(input [7:0] b);
        integer i;
        begin
            rx_line = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rx_line = b[i]; #(BIT_NS);
            end
            rx_line = 1'b1; #(BIT_NS * 2);   // stop bit + inter-byte gap
        end
    endtask

    task uart_recv(output [7:0] b);
        integer i;
        begin
            @(negedge tx_line);
            #(BIT_NS * 1.5);                 // into the middle of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = tx_line; #(BIT_NS);
            end
        end
    endtask

    reg [7:0] rpt [0:15];
    // The receiver is forked BEFORE the request goes out, and that is load
    // bearing rather than stylistic. The FPGA turns a status request around in
    // a handful of 108 MHz cycles: uart_rx raises `valid` at the end of the
    // stop bit and the first reply start bit falls ~1 bit time later. A
    // sequential "send, then listen" misses it -- uart_send does not return
    // until after its own trailing idle gap, by which point the reply is
    // already on the wire. The first version of this task did exactly that and
    // hung, having silently consumed the reply's first start bit.
    //
    // Worth recording because it is a HOST-SIDE hazard too: python/tools/
    // lcd_panel.py must have its read pending before it writes, or rely on the
    // OS buffering the reply. pyserial does buffer, which is why the same
    // mistake would not show up there -- and why finding it here is the cheaper
    // place to find it.
    task read_report;
        integer i;
        reg [7:0] b;
        begin
            fork
                uart_send(CMD_STATUS);
                begin
                    for (i = 0; i < 16; i = i + 1) begin
                        uart_recv(b);
                        rpt[i] = b;
                    end
                end
            join
        end
    endtask

    function integer rpt16(input integer lo);
        rpt16 = {rpt[lo+1], rpt[lo]};
    endfunction

    task chk_i(input [1023:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %0d, expected %0d", what, got, exp);
                errors = errors + 1;
            end else $display("  ok  %0s = %0d", what, got);
        end
    endtask

    // =======================================================================
    initial begin : main
        real duty;
        integer f0, n, bl_reset_ok;

        // ---- the backlight must stay dark through configuration and reset.
        // rst_n releases ~305 us in (2 us of modelled PLL lock, then 32768
        // cycles of power-on reset), and only then does the T2 delay start.
        #250_000;
        if (lcd_bl !== 1'b0) bl_high_early = 1'b1;

        // ---- let the design reach steady state, then check the default
        // pattern's content over one complete frame.
        wait (frames >= 2);
        @(posedge lcd_ck);
        check_sel = 0;                 // GRID, the power-on default
        f0 = frames;
        wait (frames == f0 + 1);       // exactly one full frame checked
        @(posedge lcd_ck);
        check_sel = -1;

        $display("--- geometry, measured off the pins ---");
        chk_i("DCLKs per line",      m_h_total,       EXP_H_TOTAL);
        chk_i("lines per frame",     m_v_total,       EXP_V_TOTAL);
        chk_i("active pixels/frame", frame_px_at_end, EXP_PIXELS);
        chk_i("lines with != 320 active DCLKs", lines_bad_len, 0);

        $display("--- content, pattern 0 (GRID) ---");
        chk_i("pixels checked",  px_checked, EXP_PIXELS);
        chk_i("pixel mismatches", px_errors, 0);
        chk_i("non-zero bus samples outside DE", blank_errors, 0);

        // ---- the status report must agree with what we measured ourselves.
        $display("--- status report over UART ---");
        read_report;
        chk_i("magic",              rpt[0],       8'hA5);
        chk_i("version",            rpt[1],       8'h05);
        chk_i("pll_lock bit",       rpt[2] & 1,   1);
        chk_i("timing-running bit", (rpt[2] >> 2) & 1, 1);
        chk_i("pattern",            rpt[3],       0);
        chk_i("backlight duty",     rpt[4],       64);
        chk_i("reported DCLKs per line",  rpt16(6),  EXP_H_TOTAL);
        chk_i("reported active DCLKs",    rpt16(8),  EXP_H_ACTIVE);
        chk_i("reported lines per frame", rpt16(10), EXP_V_TOTAL);
        chk_i("reported active lines",    rpt16(12), EXP_V_ACTIVE);
        if (rpt16(14) < 2) begin
            $display("FAIL: reported frame counter %0d, expected >= 2", rpt16(14));
            errors = errors + 1;
        end else $display("  ok  reported frame counter = %0d", rpt16(14));

        // ---- switch pattern over the wire and re-check content.
        $display("--- pattern switch to 1 (BARS) ---");
        uart_send(CMD_PATTERN);
        uart_send(8'd1);
        @(posedge lcd_ck);
        f0 = frames;
        wait (frames == f0 + 1);       // let the change land on a frame boundary
        @(posedge lcd_ck);
        px_checked = 0; px_errors = 0;
        check_sel = 1;
        f0 = frames;
        wait (frames == f0 + 1);
        @(posedge lcd_ck);
        check_sel = -1;
        chk_i("pixels checked",   px_checked, EXP_PIXELS);
        chk_i("pixel mismatches", px_errors,  0);
        read_report;
        chk_i("reported pattern", rpt[3], 1);

        // ---- CMD_RESET restarts the timing generator mid-frame.
        //
        // This exercises the DEFERRED restart in lcd_timing_gen. A restart
        // arrives at an arbitrary system-clock phase, and applying it
        // immediately would move every panel-facing signal at that phase --
        // possibly right at a DCLK edge, which is the one thing the quarter-
        // period offset exists to prevent. The module holds the request until
        // the next tick instead, so the checks below are that a mid-frame
        // restart produces a clean frame rather than a corrupted one, and that
        // the backlight re-arms its T2 delay rather than staying lit through a
        // restart it was supposed to gate.
        $display("--- reset (0xAA) mid-frame ---");
        uart_send(CMD_RESET);
        bl_reset_ok = 1;
        for (n = 0; n < 200; n = n + 1) begin      // 20 us, well inside TB_BL_DELAY
            #100;
            if (lcd_bl !== 1'b0) bl_reset_ok = 0;
        end
        if (!bl_reset_ok) begin
            $display("FAIL: backlight stayed on across a reset -- the T2 delay did not re-arm");
            errors = errors + 1;
        end else $display("  ok  backlight went off and re-armed its T2 delay");

        @(posedge lcd_ck);
        f0 = frames;
        wait (frames == f0 + 1);       // the restart's own frame origin
        @(posedge lcd_ck);
        px_checked = 0; px_errors = 0; lines_bad_len = 0; blank_errors = 0;
        check_sel = 1;                 // still BARS
        f0 = frames;
        wait (frames == f0 + 1);       // one complete frame after the restart
        @(posedge lcd_ck);
        check_sel = -1;
        chk_i("DCLKs per line after reset",  m_h_total,       EXP_H_TOTAL);
        chk_i("lines per frame after reset", m_v_total,       EXP_V_TOTAL);
        chk_i("active pixels after reset",   frame_px_at_end, EXP_PIXELS);
        chk_i("pixel mismatches after reset", px_errors,      0);
        chk_i("bad-length lines after reset", lines_bad_len,  0);
        chk_i("non-zero bus outside DE after reset", blank_errors, 0);

        // ---- backlight: the T2 delay, then PWM at the commanded duty.
        $display("--- backlight ---");
        if (bl_high_early) begin
            $display("FAIL: backlight was on during the power-on delay");
            errors = errors + 1;
        end else $display("  ok  backlight stayed off through reset and the T2 delay");

        measure_duty(duty);
        $display("  measured duty at default 64/256 = %0.4f", duty);
        if (duty < 0.24 || duty > 0.26) begin
            $display("FAIL: default backlight duty %0.4f, expected ~0.25", duty);
            errors = errors + 1;
        end

        uart_send(CMD_BL);
        uart_send(8'd128);
        measure_duty(duty);
        $display("  measured duty after 'B' 128 = %0.4f", duty);
        if (duty < 0.49 || duty > 0.51) begin
            $display("FAIL: commanded backlight duty %0.4f, expected ~0.50", duty);
            errors = errors + 1;
        end

        uart_send(CMD_BL);
        uart_send(8'd0);
        #(PWM_PERIOD_NS * 1.5);
        if (lcd_bl !== 1'b0) begin
            $display("FAIL: backlight not fully off at duty 0");
            errors = errors + 1;
        end else $display("  ok  duty 0 turns the backlight fully off");

        // ---- the SHIPPED backlight delay, not the one simulated above.
        $display("--- shipped defaults ---");
        if (u_defaults.BL_DELAY_CYCLES < 27_000_000) begin
            $display("FAIL: default BL_DELAY_CYCLES = %0d, below the datasheet's 250 ms T2 (27,000,000 cycles at 108 MHz)",
                     u_defaults.BL_DELAY_CYCLES);
            errors = errors + 1;
        end else $display("  ok  default BL_DELAY_CYCLES = %0d (>= 250 ms at 108 MHz)",
                          u_defaults.BL_DELAY_CYCLES);

        // The SHIPPED backlight default must be OFF. Nothing on the 40-pin
        // connector tells the FPGA whether a panel is mated, and the LP3320
        // boost takes its feedback from a sense resistor in series with the
        // panel's LED string -- so enabling it with no panel means driving an
        // open circuit at maximum. The DUT above overrides this to 64 purely so
        // the PWM duty measurements have edges to measure.
        if (u_defaults.BL_DUTY_INIT !== 8'd0) begin
            $display("FAIL: default BL_DUTY_INIT = %0d, expected 0 -- the backlight must not come up enabled into a possibly-absent panel",
                     u_defaults.BL_DUTY_INIT);
            errors = errors + 1;
        end else $display("  ok  default BL_DUTY_INIT = 0 (backlight is opt-in)");

        if (errors != 0) begin
            $display("FAIL: %0d checks failed", errors);
            $fatal(1);
        end

        $display("PASS: lcd_panel drives %0d DCLK x %0d line frames at 320x240, %0d/%0d pixels exact against the pattern oracle, status report agrees with the pins, backlight honours T2 and PWMs to command",
                 EXP_H_TOTAL, EXP_V_TOTAL, EXP_PIXELS, EXP_PIXELS);
        $finish;
    end

    // Watchdog: the sequence above spans ~5 frames at 62 Hz plus a few PWM
    // periods -- call it 90 ms. 200 ms leaves room without hiding a hang.
    initial begin
        #200_000_000;
        $display("FAIL: watchdog -- %0d frames seen, %0d pixels checked, %0d errors so far",
                 frames, px_checked, errors);
        $fatal(1);
    end
endmodule
`default_nettype wire
