`timescale 1ns/1ps
`default_nettype none
//
// Phase 4 in the REAL rate regime: source SLOWER than panel.
//
// WHY THIS EXISTS AS A SEPARATE TARGET
// ------------------------------------
// sim/targets/passthrough runs the source at ~325 Hz (8 active lines in a
// 30-line frame) against the panel's 62.2 Hz. That is the INVERSE of reality --
// the HP Prime is 37.7 Hz and the panel is 62.2 -- and the inversion hid a real
// bug for an entire development cycle.
//
// Hardware found it instead: the passthrough captured every OTHER source frame,
// 18.9 fps against 37.7 Hz. `passthrough_top` argued that two buffers suffice
// "because the reader is strictly faster than the writer". That argument is
// subtly wrong. Reader-faster-than-writer guarantees a completed capture is
// COLLECTED before it is overwritten; it does not guarantee a buffer is
// AVAILABLE at the instant the writer wants one. `ev_done` fires on the same
// clock as the next source frame's `frame_start`, and at that moment one buffer
// holds the just-finished capture awaiting the panel swap while the other is
// being displayed. There is nowhere to write, so that frame is skipped.
//
// In the fast-source regime this never shows up, because the writer is not
// trying to start a frame every 26.5 ms in the first place. The property was
// untestable in the only regime being tested.
//
// SOURCE GEOMETRY. Real line timing AND real frame timing: 1361 DOTCLKs per
// line and 259 lines per frame, exactly as docs/prime_lcd_protocol.md measured,
// giving a 26.53 ms frame = 37.70 Hz against the panel's 16.08 ms = 62.2 Hz.
// Only the ACTIVE height is reduced (8 lines instead of 240), because vertical
// active extent is a counter while the frame RATE is the thing under test here.
// This is the opposite trade from the sibling testbench and deliberately so.
//
// THIS TEST IS EXPECTED TO FAIL ON A TWO-BUFFER DESIGN. It asserts the
// behaviour that is wanted -- every source frame captured -- rather than the
// behaviour that is currently produced. That is the point: it reproduces in
// simulation, in seconds, what previously required a calculator, a panel and a
// host wall-clock to notice.
//
// Runs in ~10 s under `make simq SIM_TARGET=passthrough_slow` (Verilator).
// `make sim` (Icarus) takes several minutes and says the same thing.
//
module tb_passthrough_slow;
    localparam real CLK27_NS = 37.037037;

    localparam integer TB_BL_DELAY = 5000;

    // Real Prime timing, both axes. Active height reduced; rate untouched.
    localparam integer P_H_TOTAL = 1361, P_H_SYNC = 1, P_H_START = 242,
                       P_H_ACTIVE = 960;
    localparam integer P_V_TOTAL = 259,  P_V_SYNC = 1, P_V_START = 19,
                       P_V_ACTIVE = 8;
    localparam integer SRC_W = P_H_ACTIVE / 3;   // 320
    localparam integer SRC_H = P_V_ACTIVE;       // 8

    // How many source frames to measure over. Each is 26.53 ms, so 6 frames is
    // ~159 ms of simulated time -- the dominant cost of this testbench.
    localparam integer MEASURE_FRAMES = 6;

    // Read both frame counters this long after a boundary: >> the sampling
    // lag (us), << a source frame (26.53 ms). See the measurement window.
    localparam integer SETTLE_NS = 1_000_000;   // 1 ms

    reg clk = 1'b0;
    always #(CLK27_NS/2.0) clk = ~clk;

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
        .clk(clk), .uart_rx(1'b1), .uart_tx(tx_line), .probe(probe),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .lcd_ck(lcd_ck), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_de(lcd_de),
        .lcd_bl(lcd_bl), .leds(leds),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_cas_n(sd_cas_n),
        .O_sdram_wen_n(sd_wen_n), .O_sdram_dqm(sd_dqm),
        .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba), .IO_sdram_dq(sd_dq)
    );

    sdram_sim #(.ROWS(256)) u_mem (
        .Clk(sd_clk), .Cke(sd_cke), .Cs_n(sd_cs_n), .Ras_n(sd_ras_n),
        .Cas_n(sd_cas_n), .We_n(sd_wen_n), .Ba(sd_ba), .Addr(sd_addr),
        .Dqm(sd_dqm), .Dq(sd_dq)
    );

    integer errors = 0;

    // Park on the DUT's own source-frame boundary, so both frame counters have
    // accounted for the same frame before a measurement window opens or closes.
    task sync_to_src_frame;
        begin
            @(posedge dut.clk_s);
            wait (dut.src_frame_start === 1'b1);
            @(posedge dut.clk_s);
        end
    endtask

    task chk_i(input [1023:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %0d, expected %0d", what, got, exp);
                errors = errors + 1;
            end else $display("  ok  %0s = %0d", what, got);
        end
    endtask

    // ---- the swap invariant, same as the sibling testbench.
    reg invariant_bad = 1'b0;
    always @(posedge dut.clk_s) begin
        if (dut.rst_n) begin
            if (dut.rbuf === dut.wbuf) invariant_bad = 1'b1;
            if (dut.have_done &&
                (dut.dbuf === dut.rbuf || dut.dbuf === dut.wbuf))
                invariant_bad = 1'b1;
        end
    end

    // =======================================================================
    // Independent frame counters.
    //
    // src_frames_tb counts what the SOURCE actually emitted, observed at the
    // probe pins. dut.src_frames is what the DUT believes it captured. Counting
    // both and comparing is the whole test -- it is the simulation equivalent
    // of what passthrough.py does by timing the FPGA's counter against host
    // wall-clock, and it exists for the same reason: the DUT's internal view is
    // perfectly self-consistent while being half the truth.
    // =======================================================================
    integer src_frames_tb = 0;
    reg     src_vs_d = 1'b1;
    always @(posedge dut.clk_s) begin
        if (src_rst_n) begin
            src_vs_d <= src_vs;
            if (!src_vs && src_vs_d) src_frames_tb = src_frames_tb + 1;
        end
    end

    // ---- panel frame counter, at the pins.
    integer panel_frames = 0;
    reg     pvs_d = 1'b0;
    always @(posedge lcd_ck) begin
        if (!lcd_vs && pvs_d) panel_frames = panel_frames + 1;
        pvs_d <= lcd_vs;
    end

    // ---- pixel check, only over rows the source actually wrote.
    integer x_pos = 0, y_pos = 0;
    reg     de_d = 1'b0;
    integer check_on = 0, px_checked = 0, px_bad = 0;

    function [15:0] expect_src(input integer x, input integer y);
        integer r8, g8, b8;
        begin
            r8 = x % 256;
            g8 = y % 256;
            b8 = r8 ^ g8;
            expect_src = {r8[7:3], g8[7:2], b8[7:3]};
        end
    endfunction

    wire [15:0] got_rgb = {lcd_r, lcd_g, lcd_b};

    always @(posedge lcd_ck) begin
        if (!lcd_vs && pvs_d) y_pos = 0;
        if (lcd_de) begin
            if (!de_d) x_pos = 0;
            if (check_on && y_pos < SRC_H && x_pos < SRC_W) begin
                px_checked = px_checked + 1;
                if (got_rgb !== expect_src(x_pos, y_pos)) begin
                    if (px_bad < 8)
                        $display("FAIL: pixel (%0d,%0d): got %04h expected %04h",
                                 x_pos, y_pos, got_rgb, expect_src(x_pos, y_pos));
                    px_bad = px_bad + 1;
                end
            end
            x_pos = x_pos + 1;
        end else if (de_d) y_pos = y_pos + 1;
        de_d <= lcd_de;
    end

    // =======================================================================
    integer f_src0, f_dut0, f_pan0, d_src, d_dut, d_pan, f0;
    real    src_hz, pan_hz;
    real    t0, t1;

    initial begin : main
        repeat (40) @(posedge clk);
        src_rst_n <= 1'b1;

        // Let AUTO reach the live passthrough on its own. That needs a captured
        // frame swapped in, which at 26.5 ms per source frame takes a while --
        // deliberately not hurried with a UART command, because reaching REAL
        // unaided in the SLOW regime is itself worth confirming.
        wait (dut.mode_real === 1'b1);
        $display("--- AUTO reached live passthrough in the slow-source regime ---");

        // ---- confirm we are actually in the intended regime before asserting
        // anything about it. A testbench that silently ran the wrong rate would
        // pass while testing nothing, which is exactly the failure this whole
        // target exists to correct.
        @(posedge lcd_ck);
        f_src0 = src_frames_tb; f_pan0 = panel_frames; t0 = $realtime;
        wait (src_frames_tb == f_src0 + MEASURE_FRAMES);
        t1 = $realtime;
        d_pan = panel_frames - f_pan0;
        src_hz = MEASURE_FRAMES * 1.0e9 / (t1 - t0);
        pan_hz = d_pan          * 1.0e9 / (t1 - t0);

        $display("--- rate regime ---");
        $display("  source %0.2f Hz, panel %0.2f Hz", src_hz, pan_hz);
        if (!(src_hz > 36.0 && src_hz < 39.5)) begin
            $display("FAIL: source %0.2f Hz is not the Prime's 37.70 Hz -- this testbench is not running the regime it claims to", src_hz);
            errors = errors + 1;
        end else $display("  ok  source rate is the Prime's 37.70 Hz");
        if (!(pan_hz > src_hz)) begin
            $display("FAIL: panel %0.2f Hz is not faster than source %0.2f Hz", pan_hz, src_hz);
            errors = errors + 1;
        end else $display("  ok  panel is the faster party, as on hardware");

        // ---- THE TEST. Every source frame the calculator emitted must be
        // captured.
        //
        // The window is defined by the DUT's OWN frame boundary, not by the
        // testbench's, and this matters: the testbench counts the RAW VSYNC edge
        // at the probe pins, while the DUT counts the SAMPLED edge, after sync2
        // plus dotclk_sampler waiting for the next DOTCLK. The DUT therefore
        // lags by a few microseconds, and a window whose endpoints are sampled
        // at an arbitrary instant can straddle that lag and report an extra
        // frame -- which it duly did on the first run, "7 of 6". Aligning to
        // dut.src_frame_start removes the skew rather than tolerating it.
        //
        // Waiting on the DUT's counter also gives the right failure shape: if
        // the design drops frames, its counter advances more SLOWLY, so waiting
        // for it to reach +N takes longer and the source's count overruns. The
        // ratio then reads directly as the capture fraction.
        //
        // SETTLE is what makes the endpoints unambiguous. Both counters are read
        // 1 ms after a frame boundary -- far longer than the sampling lag
        // (microseconds) and far shorter than a frame (26.53 ms) -- so no edge
        // can be in flight at either end and the question "which counter leads?"
        // stops mattering. Two runs disagreed in OPPOSITE directions (7-of-6,
        // then 6-of-5) before this went in, which is the signature of a window
        // straddling a boundary rather than of a real discrepancy.
        sync_to_src_frame; #SETTLE_NS;
        f_src0 = src_frames_tb;
        f_dut0 = dut.src_frames;
        wait (src_frames_tb == f_src0 + MEASURE_FRAMES);
        #SETTLE_NS;
        d_dut = dut.src_frames  - f_dut0;
        d_src = src_frames_tb   - f_src0;

        $display("--- capture completeness ---");
        $display("  source emitted %0d frames, DUT captured %0d", d_src, d_dut);
        if (d_dut != d_src) begin
            $display("FAIL: captured %0d of %0d source frames (%0.1f%%) -- frames are being dropped. The writer needs a free buffer at src_frame_start, which is the same clock the previous capture completes on; if none is free that whole frame is lost. This is what a two-buffer scheme does here, and it measured 50%% on hardware.",
                     d_dut, d_src, 100.0 * d_dut / d_src);
            errors = errors + 1;
        end else $display("  ok  every source frame was captured");

        // ---- and the image is still correct in this regime.
        //
        // Align to a frame boundary FIRST, then open the window for a whole
        // frame. Opening it immediately checks only the remainder of whatever
        // frame happens to be in progress, and if that remainder is vertical
        // blanking the window sees no DE at all and reports 0 pixels checked
        // while every other assertion passes -- which is precisely what this
        // block did on its first run.
        @(posedge lcd_ck);
        f0 = panel_frames;
        wait (panel_frames == f0 + 1);
        @(posedge lcd_ck);
        px_checked = 0; px_bad = 0;
        check_on = 1;
        f0 = panel_frames;
        wait (panel_frames == f0 + 1);
        @(posedge lcd_ck);
        check_on = 0;

        chk_i("captured pixels checked",   px_checked, SRC_W * SRC_H);
        chk_i("captured pixel mismatches", px_bad,     0);
        chk_i("writer overrun",  dut.wr_overrun,  0);
        chk_i("reader underrun", dut.rd_underrun, 0);

        if (invariant_bad) begin
            $display("FAIL: rbuf/wbuf/dbuf were not three distinct buffers");
            errors = errors + 1;
        end else
            $display("  ok  rbuf/wbuf/dbuf stayed distinct throughout");

        if (errors != 0) begin
            $display("FAIL: %0d checks failed", errors);
            $fatal(1);
        end

        $display("PASS: passthrough_slow -- source at %0.2f Hz against panel %0.2f Hz (the real regime, source SLOWER), every one of %0d source frames captured, %0d pixels correct, 0 overruns, 0 underruns",
                 src_hz, pan_hz, d_src, px_checked);
        $finish;
    end

    // Two measurement windows of 6 source frames at 26.53 ms each is ~320 ms,
    // plus AUTO settling and a panel frame. 600 ms leaves room without hiding a
    // hang. Cheap under Verilator; slow under Icarus, which is the trade this
    // target was written to exploit.
    initial begin
        #600_000_000;
        $display("FAIL: watchdog -- src_frames_tb %0d, dut.src_frames %0d, panel_frames %0d, mode_real %0b, %0d errors",
                 src_frames_tb, dut.src_frames, panel_frames, dut.mode_real, errors);
        $fatal(1);
    end
endmodule
`default_nettype wire
