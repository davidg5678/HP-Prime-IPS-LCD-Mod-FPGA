`timescale 1ns/1ps
`default_nettype none
//
// Top-level testbench for src/targets/passthrough (Phase 4).
//
// The question this has to answer is the one no unit test can: do pixels that
// enter as the HP Prime's serial-RGB bus come out of the panel pins, through a
// real SDRAM frame buffer, with the right values at the right coordinates, on
// completely different timing?
//
// The chain under test is the whole thing --
//
//     video_timing_gen -> dotclk_sampler -> prime_pixel -> write FIFO
//         -> sdram_ctrl -> sdram_sim -> read FIFO -> lcd_timing_gen -> pins
//
// -- with the source built from src/common/video_timing_gen.v, an INDEPENDENT
// implementation of the Prime's protocol written for Phase 1 and validated
// against the calculator itself, and the memory modelled by
// sim/models/sdram_sim.v, which CHECKS the SDRAM protocol rather than merely
// responding to it (it caught an auto-precharge bug on its first ever run).
//
// SOURCE GEOMETRY. Real horizontal timing -- 1361 DOTCLKs per line, 242 back
// porch, 960 active = exactly 320 pixels -- but only EIGHT active lines instead
// of 240. Horizontal is where the subtleties live (triplet phase, DE gating,
// runt edges); vertical is a counter. Eight lines makes a source frame 3.0 ms
// instead of 26.5 ms, which is the difference between a testbench that runs in
// a minute and one that does not. sim/targets/prime_pixel covers the full
// 320x240 coordinate range at full Prime timing separately.
//
// The consequence is that frame-buffer rows 8..239 are never written, so the
// panel reads uninitialised SDRAM there and drives X. That is realistic -- real
// hardware shows whatever was in the die until the first frame lands -- and the
// pixel checker deliberately only covers the rows the source actually wrote.
//
module tb_passthrough;
    localparam real CLK27_NS = 37.037037;
    localparam real BIT_NS   = 1000.0;

    localparam integer TB_BL_DELAY = 5000;

    // Source: real horizontal timing, reduced vertical. See above.
    localparam integer P_H_TOTAL = 1361, P_H_SYNC = 1, P_H_START = 242,
                       P_H_ACTIVE = 960;
    localparam integer P_V_TOTAL = 30,   P_V_SYNC = 1, P_V_START = 19,
                       P_V_ACTIVE = 8;
    localparam integer SRC_W = P_H_ACTIVE / 3;   // 320
    localparam integer SRC_H = P_V_ACTIVE;       // 8

    localparam integer EXP_H_TOTAL = 371, EXP_H_ACTIVE = 320;
    localparam integer EXP_V_TOTAL = 260, EXP_V_ACTIVE = 240;

    localparam [7:0] CMD_RESET = 8'hAA, CMD_MOCK = 8'h4D, CMD_REAL = 8'h52,
                     CMD_PATTERN = 8'h50, CMD_BL = 8'h42, CMD_STATUS = 8'h53,
                     CMD_AUTO = 8'h41;
    localparam integer MODE_AUTO = 0, MODE_MOCK = 1, MODE_REAL = 2;

    reg clk = 1'b0;
    always #(CLK27_NS/2.0) clk = ~clk;

    reg  rx_line = 1'b1;
    wire tx_line;

    // ---------------------------------------------------------- Prime source
    wire       src_dotclk, src_hs, src_vs, src_de;
    wire [7:0] src_d;
    reg        src_rst_n = 1'b0;

    video_timing_gen #(
        .DOTCLK_DIV(8),
        .H_TOTAL(P_H_TOTAL), .H_SYNC(P_H_SYNC), .H_START(P_H_START),
        .H_ACTIVE(P_H_ACTIVE),
        .V_TOTAL(P_V_TOTAL), .V_SYNC(P_V_SYNC), .V_START(P_V_START),
        .V_ACTIVE(P_V_ACTIVE)
    ) u_src (
        .clk(dut.clk_s), .rst_n(src_rst_n), .restart(1'b0),
        .dotclk(src_dotclk), .hsync(src_hs), .vsync(src_vs), .de(src_de),
        .data(src_d)
    );

    // Probe channel map, exactly as la_capture/frame_capture wire it:
    //   bit0 DOTCLK, 1 HSYNC, 2 VSYNC, 3 DE, 4..11 D0..D7
    wire [11:0] probe = {src_d, src_de, src_vs, src_hs, src_dotclk};

    // ------------------------------------------------------------------- DUT
    wire [4:0] lcd_r, lcd_b;
    wire [5:0] lcd_g;
    wire       lcd_ck, lcd_hs, lcd_vs, lcd_de, lcd_bl;
    wire [5:0] leds;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_wen_n;
    wire [3:0]  sd_dqm;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [31:0] sd_dq;

    passthrough_top #(.BL_DELAY_CYCLES(TB_BL_DELAY)) dut (
        .clk(clk), .uart_rx(rx_line), .uart_tx(tx_line), .probe(probe),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .lcd_ck(lcd_ck), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_de(lcd_de),
        .lcd_bl(lcd_bl), .leds(leds),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n),
        .O_sdram_wen_n(sd_wen_n), .O_sdram_dqm(sd_dqm),
        .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba), .IO_sdram_dq(sd_dq)
    );

    // ROWS shrunk from 2048 to 256: a frame is 150 rows and the two buffers sit
    // in different BANKS, so nothing above row 149 is ever touched. This keeps
    // the model's storage array at 1 MB instead of 8 MB.
    sdram_sim #(.ROWS(256)) u_mem (
        .Clk(sd_clk), .Cke(sd_cke), .Cs_n(sd_cs_n), .Ras_n(sd_ras_n),
        .Cas_n(sd_cas_n), .We_n(sd_wen_n), .Ba(sd_ba), .Addr(sd_addr),
        .Dqm(sd_dqm), .Dq(sd_dq)
    );

    integer errors = 0;
    task note_err(input [1023:0] msg);
        begin
            $display("FAIL: %0s", msg);
            errors = errors + 1;
        end
    endtask

    // =======================================================================
    // THE INVARIANT THE SWAP LOGIC RESTS ON
    //
    // passthrough_top argues that ev_swap and ev_done can never coincide,
    // because wr_active implies !wdone. If that were ever false the two would
    // assign `wdone` in the same cycle and the later non-blocking assignment
    // would silently win, presenting a stale buffer. Checked on every clock
    // rather than reasoned about once.
    // =======================================================================
    reg invariant_bad = 1'b0;
    always @(posedge dut.clk_s) begin
        if (dut.rst_n && dut.wr_active && dut.wdone) invariant_bad = 1'b1;
    end

    // =======================================================================
    // Oracles
    // =======================================================================
    // video_timing_gen's pattern: R = x[7:0], G = y[7:0], B = x^y, with x an
    // 8-bit counter that wraps at 256 inside a 320-pixel line.
    function [15:0] expect_src(input integer x, input integer y);
        integer r8, g8, b8;
        begin
            r8 = x % 256;
            g8 = y % 256;
            b8 = r8 ^ g8;
            expect_src = {r8[7:3], g8[7:2], b8[7:3]};
        end
    endfunction

    // test_pattern.v pattern 0, GRID. Written from its documented spec.
    function [15:0] expect_mock(input integer x, input integer y);
        integer r, g, b;
        begin
            r = 0; g = 0; b = 0;
            if (x == 0 || x == 319 || y == 0 || y == 239) begin
                r = 31; g = 63; b = 31;
            end else if (x == 160 || y == 120) begin
                r = 31; g = 0; b = 0;
            end else if ((x % 32) == 0 || (y % 32) == 0) begin
                r = 8; g = 16; b = 8;
            end
            expect_mock = {r[4:0], g[5:0], b[4:0]};
        end
    endfunction

    // =======================================================================
    // Panel-side capture, sampled at the DCLK rising edge -- the way the panel
    // samples, and deterministic where an @(negedge lcd_hs) block would race
    // the coincident VSYNC edge at the frame origin.
    // =======================================================================
    reg  hs_d = 1'b0, vs_d = 1'b0, de_d = 1'b0;
    integer x_pos = 0, y_pos = 0;
    integer frames = 0;
    integer ck_in_line = 0, lines_in_frame = 0;
    integer m_h_total = -1, m_v_total = -1;
    integer px_this_frame = 0, frame_px_at_end = -1;

    integer check_mode = 0;    // 0 = off, 1 = MOCK/GRID, 2 = REAL/captured
    integer px_checked = 0, px_bad = 0, blank_bad = 0;

    wire [15:0] got_rgb = {lcd_r, lcd_g, lcd_b};
    reg  [15:0] want_rgb;

    // Which effective mode was in force while pixels were actually being
    // DISPLAYED, accumulated across the check window.
    //
    // These replaced a point-sample of dut.mode_real taken after
    // `wait (frames == f0+1)`, which failed while every pixel check passed --
    // a contradiction that could only mean the sample, not the pixels, was
    // wrong. `frames` counts VSYNC edges observed at the PINS, whereas
    // mode_real is latched on the timing generator's internal frame tick a few
    // cycles EARLIER, so the sample landed one frame boundary late. That is the
    // same pin-versus-internal skew the REAL-mode comment below records for
    // ev_swap; it is apparently very easy to reintroduce.
    //
    // Gating on lcd_de removes the skew entirely rather than compensating for
    // it: it only looks at cycles where the mux's output is on the glass, and
    // it asserts over the WHOLE frame instead of at one instant, so a mode that
    // flipped mid-scan would be caught too.
    reg saw_real_px, saw_mock_px;

    always @(posedge lcd_ck) begin
        if (!lcd_vs && vs_d) begin
            frame_px_at_end = px_this_frame;
            m_v_total = lines_in_frame + 1;
            px_this_frame = 0; y_pos = 0; lines_in_frame = 0;
            frames = frames + 1;
        end else if (!lcd_hs && hs_d) begin
            lines_in_frame = lines_in_frame + 1;
        end

        if (!lcd_hs && hs_d) begin
            m_h_total = ck_in_line + 1;
            ck_in_line = 0;
        end else begin
            ck_in_line = ck_in_line + 1;
        end

        // Blocking, to match the counters in this block -- these are testbench
        // bookkeeping, and the main process clears them with blocking
        // assignments between windows.
        if (lcd_de && check_mode != 0) begin
            if (dut.mode_real) saw_real_px = 1'b1;
            else               saw_mock_px = 1'b1;
        end

        if (lcd_de) begin
            if (!de_d) x_pos = 0;
            // In REAL mode only the rows the source actually wrote are
            // meaningful; the rest of the buffer is uninitialised memory.
            if (check_mode == 1 ||
                (check_mode == 2 && y_pos < SRC_H && x_pos < SRC_W)) begin
                want_rgb = (check_mode == 1) ? expect_mock(x_pos, y_pos)
                                             : expect_src(x_pos, y_pos);
                px_checked = px_checked + 1;
                if (got_rgb !== want_rgb) begin
                    if (px_bad < 8)
                        $display("FAIL: pixel (%0d,%0d) mode %0d: got %04h expected %04h",
                                 x_pos, y_pos, check_mode, got_rgb, want_rgb);
                    px_bad = px_bad + 1;
                end
            end
            x_pos = x_pos + 1;
            px_this_frame = px_this_frame + 1;
        end else begin
            if (got_rgb !== 16'h0000) blank_bad = blank_bad + 1;
            if (de_d) y_pos = y_pos + 1;
        end

        hs_d <= lcd_hs; vs_d <= lcd_vs; de_d <= lcd_de;
    end

    // =======================================================================
    // UART, at the real 1 Mbaud line rate
    // =======================================================================
    task uart_send(input [7:0] b);
        integer i;
        begin
            rx_line = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin rx_line = b[i]; #(BIT_NS); end
            rx_line = 1'b1; #(BIT_NS * 2);
        end
    endtask

    task uart_recv(output [7:0] b);
        integer i;
        begin
            @(negedge tx_line);
            #(BIT_NS * 1.5);
            for (i = 0; i < 8; i = i + 1) begin b[i] = tx_line; #(BIT_NS); end
        end
    endtask

    reg [7:0] rpt [0:23];
    // The receiver is forked BEFORE the request goes out: the FPGA replies
    // within a few 108 MHz cycles, so a sequential send-then-listen misses the
    // first start bit. See the same note in sim/targets/lcd_panel.
    task read_report;
        integer i;
        reg [7:0] b;
        begin
            fork
                uart_send(CMD_STATUS);
                begin
                    for (i = 0; i < 24; i = i + 1) begin
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
        integer f0;

        repeat (40) @(posedge clk);
        src_rst_n <= 1'b1;          // the calculator starts driving

        // ===================================================================
        // PHASE 1 -- AUTO before any captured frame exists.
        //
        // The power-on default is AUTO, and with no complete capture swapped in
        // yet it must resolve to the MOCK pattern. This is the reading that
        // makes a dark bench diagnosable: a panel showing GRID says the FPGA,
        // the FFC and the whole output path are fine and only the calculator is
        // missing. NOTHING IS SENT OVER THE UART in this phase -- that is the
        // point, since the shipped box has no host attached.
        //
        // Timing, so the window is understood rather than tuned: the source
        // completes a frame every ~3 ms, but have_frame is only set when a
        // buffer is SWAPPED, which happens on a panel frame tick (~16 ms), and
        // mode_real samples the pre-swap value on that same edge. So the first
        // TWO panel frames are MOCK and the switch lands on the third.
        // ===================================================================
        wait (frames >= 1);
        @(posedge lcd_ck);
        saw_real_px = 0; saw_mock_px = 0;
        check_mode = 1;
        f0 = frames;
        wait (frames == f0 + 1);
        @(posedge lcd_ck);
        check_mode = 0;

        $display("--- AUTO, no capture yet: internal pattern -> panel ---");
        chk_i("DCLKs per line",      m_h_total,       EXP_H_TOTAL);
        chk_i("lines per frame",     m_v_total,       EXP_V_TOTAL);
        chk_i("active pixels/frame", frame_px_at_end, EXP_H_ACTIVE * EXP_V_ACTIVE);
        chk_i("pixels checked",      px_checked,      EXP_H_ACTIVE * EXP_V_ACTIVE);
        chk_i("pixel mismatches",    px_bad,          0);
        chk_i("non-zero bus outside DE", blank_bad,   0);
        chk_i("no REAL pixel displayed all frame", saw_real_px, 0);
        chk_i("MOCK pixels were displayed",        saw_mock_px, 1);

        // ===================================================================
        // PHASE 2 -- AUTO switches itself to the live passthrough.
        //
        // Still no UART traffic. If this passes, the bitstream is a standalone
        // box: power on, calculator in, panel out. That is the entire point of
        // Phase 4, and it is checked here by waiting rather than by commanding.
        // ===================================================================
        $display("--- AUTO switches itself: HP Prime -> SDRAM -> panel ---");
        @(posedge lcd_ck);
        f0 = frames;
        wait (frames == f0 + 2);
        @(posedge lcd_ck);
        px_checked = 0; px_bad = 0; blank_bad = 0;
        saw_real_px = 0; saw_mock_px = 0;
        check_mode = 2;
        f0 = frames;
        wait (frames == f0 + 1);
        @(posedge lcd_ck);
        check_mode = 0;

        chk_i("switched with no host command", saw_real_px, 1);
        chk_i("no MOCK pixel displayed all frame", saw_mock_px, 0);
        chk_i("captured pixels checked", px_checked, SRC_W * SRC_H);
        chk_i("captured pixel mismatches", px_bad,   0);
        chk_i("non-zero bus outside DE",  blank_bad, 0);
        chk_i("DCLKs per line still",     m_h_total, EXP_H_TOTAL);
        chk_i("lines per frame still",    m_v_total, EXP_V_TOTAL);

        // ---- telemetry must agree with what the pins did.
        $display("--- status report ---");
        read_report;
        chk_i("magic",            rpt[0], 8'hA5);
        chk_i("version",          rpt[1], 8'h07);
        chk_i("pll_lock bit",     rpt[2]       & 1, 1);
        chk_i("sdram_init bit",  (rpt[2] >> 1) & 1, 1);
        chk_i("effective mode==REAL bit", (rpt[2] >> 2) & 1, 1);
        chk_i("panel-running bit",(rpt[2] >> 4) & 1, 1);
        chk_i("writer overrun bit",(rpt[2] >> 5) & 1, 0);
        chk_i("reader underrun bit",(rpt[2] >> 6) & 1, 0);
        // Requested mode is still AUTO even though the effective mode is REAL.
        // These two disagreeing is the whole diagnostic value of byte 5.
        chk_i("requested mode still AUTO", rpt[5] & 3,        MODE_AUTO);
        chk_i("have_frame bit",           (rpt[5] >> 2) & 1,  1);

        // The SHIPPED backlight default, read back off the wire rather than
        // asserted about the source. It must be 0: PWM dimming does not work on
        // this board (the pin is the LP3320's ENABLE and 25% duty never clears
        // soft-start), so any nonzero-but-not-255 default produces a dark panel
        // while this very report claims the backlight is on. The testbench
        // overrides BL_DELAY_CYCLES for runtime but deliberately does NOT
        // override BL_DUTY_INIT, so this checks what hardware will get.
        chk_i("shipped backlight duty", rpt[4], 0);
        chk_i("backlight-on bit",      (rpt[2] >> 3) & 1, 0);
        chk_i("reported DCLKs per line",  rpt16(6),  EXP_H_TOTAL);
        chk_i("reported active DCLKs",    rpt16(8),  EXP_H_ACTIVE);
        chk_i("reported lines per frame", rpt16(10), EXP_V_TOTAL);
        chk_i("reported active lines",    rpt16(12), EXP_V_ACTIVE);
        chk_i("source lines in last frame", rpt16(18), SRC_H);
        chk_i("source pixels in last line", rpt16(20), SRC_W);
        chk_i("runt DOTCLK edges",          rpt16(22), 0);
        if (rpt16(16) < 2) begin
            $display("FAIL: source frames captured = %0d, expected >= 2", rpt16(16));
            errors = errors + 1;
        end else $display("  ok  source frames captured = %0d", rpt16(16));

        // ===================================================================
        // PHASE 3 -- the host override, in both directions.
        //
        // CMD_MOCK must WIN over AUTO even though have_frame is set and AUTO
        // would choose REAL. A forced mode has to be absolute, or "put the test
        // pattern up so I can check the panel wiring" stops being available
        // exactly when a capture is running -- which is precisely when you want
        // to ask whether a wrong-looking image is the panel's fault or the
        // calculator's.
        // ===================================================================
        $display("--- forced MOCK overrides AUTO ---");
        uart_send(CMD_MOCK);
        @(posedge lcd_ck);
        f0 = frames;
        wait (frames == f0 + 1);       // let the change land on a frame boundary
        @(posedge lcd_ck);
        px_checked = 0; px_bad = 0;
        saw_real_px = 0; saw_mock_px = 0;
        check_mode = 1;
        f0 = frames;
        wait (frames == f0 + 1);
        @(posedge lcd_ck);
        check_mode = 0;
        chk_i("forced MOCK beat AUTO",         saw_real_px, 0);
        chk_i("pixels checked back in MOCK",   px_checked, EXP_H_ACTIVE * EXP_V_ACTIVE);
        chk_i("pixel mismatches back in MOCK", px_bad,     0);

        read_report;
        chk_i("requested mode now MOCK",  rpt[5] & 3,       MODE_MOCK);
        chk_i("effective mode==REAL bit", (rpt[2] >> 2) & 1, 0);
        chk_i("have_frame still set",     (rpt[5] >> 2) & 1, 1);

        // ---- forced REAL, the documented diagnostic command.
        $display("--- forced REAL ---");
        uart_send(CMD_REAL);
        @(posedge lcd_ck);
        f0 = frames;
        wait (frames == f0 + 2);
        chk_i("forced REAL took effect", dut.mode_real, 1);
        read_report;
        chk_i("requested mode now REAL", rpt[5] & 3, MODE_REAL);

        // ---- and CMD_AUTO hands control back. have_frame is still set, so
        // AUTO resolves straight to REAL rather than dropping through MOCK.
        $display("--- CMD_AUTO returns control to the bitstream ---");
        uart_send(CMD_AUTO);
        @(posedge lcd_ck);
        f0 = frames;
        wait (frames == f0 + 2);
        chk_i("AUTO resolves to REAL", dut.mode_real, 1);
        read_report;
        chk_i("requested mode back to AUTO", rpt[5] & 3, MODE_AUTO);

        if (invariant_bad) begin
            $display("FAIL: wr_active and wdone were set simultaneously -- the swap logic's mutual-exclusion invariant does not hold");
            errors = errors + 1;
        end else
            $display("  ok  wr_active/wdone stayed mutually exclusive throughout");

        if (errors != 0) begin
            $display("FAIL: %0d checks failed", errors);
            $fatal(1);
        end

        // The summary states the source geometry it ACTUALLY ran, not the one
        // it resembles. An earlier version of this line claimed "37.7 Hz-class
        // timing", which was true of the LINE (1361 DOTCLKs, real porches) and
        // false of the FRAME: 30 lines repeats at ~325 Hz, five times FASTER
        // than the panel, where the real calculator is slower. That matters
        // because the double buffer's sufficiency argument rests on the reader
        // being the faster party, so the summary named the one regime the run
        // never entered. See the note above P_V_TOTAL.
        $display("PASS: passthrough -- %0d x %0d source pixels captured from a real %0d-DOTCLK line (%0d-line frame, source faster than panel), buffered in SDRAM and re-emitted exactly on %0d x %0d panel timing at 62 Hz; AUTO reached the live passthrough with no host command, forced MOCK/REAL/AUTO all verified, 0 overruns, 0 underruns",
                 SRC_W, SRC_H, P_H_TOTAL, P_V_TOTAL, EXP_H_TOTAL, EXP_V_TOTAL);
        $finish;
    end

    // Twelve panel frames at 62 Hz is ~195 ms, plus four status reports and the
    // AUTO settling time. 320 ms leaves room without hiding a hang.
    initial begin
        #320_000_000;
        $display("FAIL: watchdog -- %0d panel frames, check_mode %0d, %0d checked, %0d bad, %0d errors",
                 frames, check_mode, px_checked, px_bad, errors);
        $fatal(1);
    end
endmodule
`default_nettype wire
