`timescale 1ns/1ps
`default_nettype none
//
// PHASE 4: live passthrough. HP Prime -> SDRAM frame buffer -> physical panel,
// entirely inside the FPGA.
//
// This is the composition Phase 1's capture path and Phase 3's driver were
// built for, and it is the point at which the host leaves the video path
// altogether. The UART carries control and telemetry at a few bytes per second;
// the pixels never touch it. That is the whole argument for this phase: the
// serial link measured ~80 KB/s and topped out at 2.6 fps even after 4.6x RLE,
// while this path runs at the SDRAM's 432 MB/s -- about 4000x -- and needs no
// compression at all.
//
// ---------------------------------------------------------------------------
// WHY THIS CANNOT BE A WIRE-THROUGH -- measured, not assumed
// ---------------------------------------------------------------------------
// Every temporal figure of the Prime's output is illegal for the panel:
//
//                     HP Prime (measured)   Panel (datasheet)
//     DOTCLK          13.289 MHz            5 / 6 / 8 MHz
//     line period     102.4 us              55 / 60 / 65 us
//     frame rate      37.70 Hz              ~58-68 Hz
//     resolution      320 x 240             320 x 240   <- the only match
//
// So the frame must be captured, buffered, and re-emitted on independently
// generated panel-legal timing. See docs/prime_lcd_protocol.md and
// docs/panel_afy320240a0.md. The rate mismatch is not incidental -- it is what
// forces the double buffer below.
//
// ---------------------------------------------------------------------------
// RATE BUDGET (this is what makes a single-word SDRAM controller sufficient)
// ---------------------------------------------------------------------------
//     writer   320x240 at 37.70 Hz = 2.90 Mpixel/s = 1.45 MW/s  (2 px per word)
//     reader   320x240 at 62.20 Hz = 4.78 Mpixel/s = 2.39 MW/s
//     total                                          3.84 MW/s
//     sdram_ctrl delivers                           ~10.8  MW/s   -> 36% used
//
// There is no burst mode here and none is needed. `docs/sdram.md` notes bursts
// as the obvious next gain; this design is the evidence that they are not yet
// the bottleneck.
//
// ---------------------------------------------------------------------------
// DOUBLE BUFFERING, and the assumption it rests on
// ---------------------------------------------------------------------------
// The writer fills `wbuf`, the panel reads `rbuf`, and they are never the same.
// Buffers exchange at the PANEL's frame boundary, so the panel never sees a
// frame torn mid-scan.
//
// Two buffers suffice only because the reader is strictly FASTER than the
// writer (62.2 Hz against 37.7 Hz): the panel always finishes a frame before
// the calculator finishes the next one, so a completed capture is always
// collected before the writer needs the buffer back. Were the panel slower,
// this would need three buffers. The invariant that encodes it -- `wr_active`
// and `wdone` are never both set -- is asserted continuously in
// sim/targets/passthrough, because it is the thing that makes the swap logic
// race-free rather than merely usually-right.
//
// Frames are DROPPED, not queued, when the calculator outruns the swap. That is
// correct for a display: showing the newest complete frame is the goal, and
// 37.7 Hz into 62.2 Hz means some frames are shown twice regardless.
//
// ---------------------------------------------------------------------------
// AUTO / MOCK / REAL, and why the default is not MOCK here
// ---------------------------------------------------------------------------
// Both pixel sources are instantiated and BOTH RUN CONTINUOUSLY; only the final
// mux is switched, at runtime. Running the capture path even while the panel
// shows the mock pattern is deliberate -- the status report's source-frame
// counter then answers "is the calculator actually connected and driving?"
// without disturbing what is on the panel, which is the first question to ask
// when a passthrough shows nothing.
//
// CLAUDE.md's mock-mode convention says the runtime mux defaults to MOCK at
// power-on, and for Phases 1 and 3 that is right: bring-up should prove the
// output path before trusting the input path. But this phase's PURPOSE is to be
// a standalone box -- calculator in, panel out, no computer anywhere -- and a
// bitstream that sits on a test pattern until a host sends 0x52 cannot do that
// job at all. The convention's real content is "both paths in ONE bitstream,
// switchable at runtime without re-synthesising", and that is preserved
// exactly. Only the DEFAULT changes, and it changes to something strictly more
// informative than either fixed choice:
//
//     MODE_AUTO (reset default)  mock pattern until a complete captured frame
//                                has been swapped in, then live passthrough,
//                                and it stays there.
//     MODE_MOCK                  forced test pattern.
//     MODE_REAL                  forced passthrough.
//
// AUTO beats defaulting to REAL because of what each one shows when the
// calculator ISN'T driving: REAL shows black, which is indistinguishable from a
// dead bitstream, an unseated FFC or a backlight left at zero -- the least
// informative failure mode in existence, and the one docs/verification.md is
// written against. AUTO shows the GRID pattern, which says "the FPGA is alive,
// the panel is wired, the output path works, and the thing that is missing is
// the calculator." That is a diagnosis rather than a mystery, delivered with no
// host attached.
//
// The switch is gated on `have_frame` -- set when a captured buffer has been
// SWAPPED to the reader, not merely captured -- and is latched at the panel's
// frame boundary, so the changeover cannot tear a frame or present a buffer
// that is still being filled.
//
// HOST PROTOCOL
//     0xAA        reset (returns the mux to AUTO)
//     0x41  'A'   force AUTO  (the power-on behaviour described above)
//     0x4D  'M'   force MOCK  (internal test pattern -> panel)
//     0x52  'R'   force REAL  (captured frame buffer -> panel)
//     0x50  'P'+1 select mock pattern, next byte = index
//     0x42  'B'+1 backlight PWM duty, next byte = 0..255
//     0x53  'S'   status: the 24-byte report below
//
// REPORT (24 bytes, little-endian, prefix 'S')
//     0      0xA5 magic
//     1      0x07 protocol version
//     2      status: bit0 pll_lock, bit1 sdram_init, bit2 EFFECTIVE mode==REAL,
//                    bit3 backlight on, bit4 panel running,
//                    bit5 writer overrun, bit6 reader underrun
//     3      mock pattern index
//     4      backlight duty
//     5      mux: bits1:0 REQUESTED mode (0 AUTO, 1 MOCK, 2 REAL),
//                 bit2 have_frame (a captured buffer has been swapped in)
//
//            Byte 5 and bit 2 of byte 2 are deliberately separate. In AUTO they
//            disagree until the first frame lands, and that disagreement is the
//            single most useful reading in the report: "requested AUTO,
//            effective MOCK, have_frame 0" says the calculator is not driving,
//            which is a different fault from "effective REAL, 0 source frames".
//     6..7   panel DCLKs per line          expect 371
//     8..9   panel active DCLKs per line   expect 320
//     10..11 panel lines per frame         expect 260
//     12..13 panel active lines per frame  expect 240
//     14..15 panel frame counter
//     16..17 source frames captured
//     18..19 source lines in the last frame   expect 240
//     20..21 source pixels in the last line   expect 320
//     22..23 runt DOTCLK edges rejected
//
// THE SDRAM PORT NAMES ARE LOAD-BEARING; see docs/sdram.md.
//
module passthrough_top #(
    parameter integer BL_DELAY_CYCLES = 27_000_000,   // 250 ms at 108 MHz
    // BACKLIGHT OFF AT RESET -- do not "helpfully" raise this. Measured on
    // hardware during Phase 3 (PROGRESS.md 2026-08-04), from both directions:
    //
    //   * PWM DIMMING DOES NOT WORK ON THIS BOARD. The pin drives the LP3320's
    //     ENABLE, not a dimming input. At ~1 kHz and 25% duty the 250 us
    //     on-time is shorter than the converter's soft-start, so it never
    //     reaches regulation: the panel stays DARK while the status report says
    //     the backlight is ON. That is the worst possible combination, and an
    //     earlier version of this file shipped exactly it (BL_DUTY_INIT = 64).
    //     BL = 255 (99.6%, effectively static) is the working setting.
    //
    //   * WITH NO PANEL MATED the boost drives an open circuit at maximum. Its
    //     feedback comes from R31 in series with the PANEL's LED string, so
    //     with no LED current FB never reaches threshold. A display driver must
    //     not enable a boost into a load it cannot detect, and nothing on the
    //     40-pin connector reports back.
    //
    // So the backlight is opt-in, exactly as src/targets/lcd_panel ships it.
    parameter [7:0]   BL_DUTY_INIT    = 8'd0
) (
    input  wire        clk,       // pin 4, 27 MHz
    input  wire        uart_rx,   // pin 70
    output wire        uart_tx,   // pin 69
    input  wire [11:0] probe,     // same channel map and pins as frame_capture

    output reg  [4:0]  lcd_r,     // pins 38..42 = R7..R3
    output reg  [5:0]  lcd_g,     // pins 32..37 = G7..G2
    output reg  [4:0]  lcd_b,     // pins 27..31 = B7..B3
    output wire        lcd_ck,    // pin 77
    output wire        lcd_hs,    // pin 25
    output wire        lcd_vs,    // pin 26
    output wire        lcd_de,    // pin 48
    output wire        lcd_bl,    // pin 49

    output wire [5:0]  leds,

    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    localparam integer CLK_HZ = 108_000_000;
    localparam integer BAUD   = 1_000_000;

    localparam integer FB_W = 320, FB_H = 240;
    localparam integer WORDS_PER_LINE = FB_W / 2;          // 160, two px per word
    localparam [20:0]  FB_WORDS   = WORDS_PER_LINE * FB_H; // 38,400
    // Buffers half the die apart. The address map is {bank[1:0], row[10:0],
    // col[7:0]} (docs/sdram.md), so a stride of 2^19 puts buffer 0 in bank 0
    // and buffer 1 in bank 1 rather than in two distant rows of the same bank.
    // With today's single-word controller that changes nothing -- every access
    // already pays a full activate/precharge -- but it costs nothing now and it
    // is the layout an open-row or burst policy would need, which docs/sdram.md
    // names as the first optimisation to reach for if bandwidth ever tightens.
    // A frame is 38,400 words = 150 rows, so each buffer occupies rows 0..149
    // of its own bank.
    localparam [20:0]  BUF_STRIDE = 21'd524288;

    localparam [7:0] CMD_RESET = 8'hAA, CMD_MOCK = 8'h4D, CMD_REAL = 8'h52,
                     CMD_PATTERN = 8'h50, CMD_BL = 8'h42, CMD_STATUS = 8'h53,
                     CMD_AUTO = 8'h41;
    // Version 7: byte 5 carries the requested mode + have_frame, which version
    // 6 did not have. The version byte is also this project's cheapest hardware
    // diagnostic -- a reply whose length and version do not match the target you
    // think you flashed means the board reset and reconfigured from flash (see
    // CLAUDE.md). Bump it whenever the report's meaning changes.
    localparam [7:0] HDR_MAGIC = 8'hA5, HDR_VERSION = 8'h07;
    localparam [4:0] HDR_LAST  = 5'd23;

    localparam [1:0] MODE_AUTO = 2'd0, MODE_MOCK = 2'd1, MODE_REAL = 2'd2;

    // ------------------------------------------------------------ clocking
    wire clk_s, pll_lock;
    pll_27_108 u_pll (.clkin(clk), .clkout(clk_s), .lock(pll_lock));

    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;
    always @(posedge clk_s) begin
        if (!pll_lock) begin por_cnt <= 16'd0; rst_n <= 1'b0; end
        else begin
            if (!por_cnt[15]) por_cnt <= por_cnt + 16'd1;
            rst_n <= por_cnt[15];
        end
    end

    // ------------------------------------------------------------- command
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk_s), .rst_n(rst_n), .rx(uart_rx), .data(rx_data), .valid(rx_valid)
    );

    reg       do_reset, do_status;
    reg [1:0] mode_sel;               // what the HOST asked for
    reg [2:0] pattern;
    reg [7:0] bl_duty;
    reg       arg_wait, arg_is_bl;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            do_reset <= 1'b0; do_status <= 1'b0;
            mode_sel <= MODE_AUTO;        // standalone by default -- see header
            pattern <= 3'd0; bl_duty <= BL_DUTY_INIT;
            arg_wait <= 1'b0; arg_is_bl <= 1'b0;
        end else begin
            do_reset <= 1'b0; do_status <= 1'b0;
            if (rx_valid) begin
                if (arg_wait) begin
                    arg_wait <= 1'b0;
                    if (arg_is_bl) bl_duty <= rx_data;
                    else           pattern <= rx_data[2:0];
                end else case (rx_data)
                    // CMD_RESET returns the mux to AUTO along with everything
                    // else: a resync means "go back to the power-on state", and
                    // leaving one register behind is how a resync stops being a
                    // reliable way out of a confused state.
                    CMD_RESET:   begin do_reset <= 1'b1; mode_sel <= MODE_AUTO; end
                    CMD_STATUS:  do_status <= 1'b1;
                    CMD_AUTO:    mode_sel <= MODE_AUTO;
                    CMD_MOCK:    mode_sel <= MODE_MOCK;
                    CMD_REAL:    mode_sel <= MODE_REAL;
                    CMD_PATTERN: begin arg_wait <= 1'b1; arg_is_bl <= 1'b0; end
                    CMD_BL:      begin arg_wait <= 1'b1; arg_is_bl <= 1'b1; end
                    default: ;
                endcase
            end
        end
    end

    // ==================================================== capture (writer)
    wire [11:0] bus_s;
    sync2 #(.W(12)) u_sync (.clk(clk_s), .rst_n(rst_n), .d(probe), .q(bus_s));

    // la_capture's channel map: bit0 DOTCLK, 1 HSYNC, 2 VSYNC, 3 DE, 4..11 D0..D7.
    wire        s_dotclk = bus_s[0];
    wire [10:0] s_bus    = bus_s[11:1];

    wire        smp_valid;
    wire [10:0] smp;
    wire [15:0] runts;
    dotclk_sampler u_smp (
        .clk(clk_s), .rst_n(rst_n), .arm(do_reset),
        .dotclk_s(s_dotclk), .bus_s(s_bus),
        .sample_valid(smp_valid), .sample(smp), .runts(runts)
    );

    wire        pix_valid, src_frame_start;
    wire [15:0] pix, src_lines, src_px_line;
    wire [9:0]  pix_x, pix_y;
    prime_pixel #(.MAX_X(FB_W), .MAX_Y(FB_H)) u_pix (
        .clk(clk_s), .rst_n(rst_n),
        .sample_valid(smp_valid), .sample(smp),
        .pix_valid(pix_valid), .pix(pix), .pix_x(pix_x), .pix_y(pix_y),
        .frame_start(src_frame_start),
        .lines_seen(src_lines), .px_in_line(src_px_line)
    );

    // ============================================================ panel out
    wire       tg_tick, tg_nxt_de, tg_frame;
    wire [9:0] tg_nxt_x, tg_nxt_y;
    lcd_timing_gen u_tg (
        .clk(clk_s), .rst_n(rst_n), .restart(do_reset),
        .dclk(lcd_ck), .hsync_n(lcd_hs), .vsync_n(lcd_vs), .de(lcd_de),
        .tick(tg_tick), .nxt_de(tg_nxt_de), .nxt_x(tg_nxt_x), .nxt_y(tg_nxt_y),
        .frame_tick(tg_frame)
    );

    wire [4:0] pat_r, pat_b;
    wire [5:0] pat_g;
    test_pattern u_pat (
        .x(tg_nxt_x), .y(tg_nxt_y), .sel(pattern),
        .r(pat_r), .g(pat_g), .b(pat_b)
    );

    // ======================================================== frame buffers
    reg wbuf, rbuf, wdone, wr_active;
    wire [20:0] wbase = wbuf ? BUF_STRIDE : 21'd0;
    wire [20:0] rbase = rbuf ? BUF_STRIDE : 21'd0;

    // Address of the word holding pixel (x,y): y * 160 + x/2. Written as two
    // shifts and an add rather than a multiply -- 160 = 128 + 32 -- so this
    // costs an adder instead of inferring a DSP block on the pixel path.
    wire [20:0] py21     = {11'd0, pix_y};
    wire [20:0] row_base = (py21 << 7) + (py21 << 5);
    wire [20:0] w_addr   = wbase + row_base + {11'd0, pix_x[9:1]};

    // ---- write FIFO. Absorbs refresh stalls and read-priority arbitration.
    // A word arrives every ~49 cycles at the Prime's rate; an access takes ~10,
    // so eight entries is far more than the worst case. Overrun is REPORTED,
    // never silently tolerated -- the same rule frame_capture follows.
    localparam integer WFD = 8;
    reg [31:0] wfifo_d [0:WFD-1];
    reg [20:0] wfifo_a [0:WFD-1];
    reg [3:0]  wf_wr, wf_rd;
    wire [3:0] wf_cnt   = wf_wr - wf_rd;
    wire       wf_full  = (wf_cnt >= WFD[3:0]);
    wire       wf_empty = (wf_wr == wf_rd);

    // ---- read FIFO. The panel's deadline is hard: a word must be there when
    // the DCLK tick arrives or a pixel is visibly wrong. Sixteen entries covers
    // 576 cycles of stall against a word needed every 36.
    localparam integer RFD = 16;
    reg [31:0] rfifo [0:RFD-1];
    reg [4:0]  rf_wr, rf_rd;
    wire [4:0] rf_cnt   = rf_wr - rf_rd;
    wire       rf_full  = (rf_cnt >= RFD[4:0]);
    wire       rf_empty = (rf_wr == rf_rd);

    reg [20:0] fetch_idx;
    reg        rd_pending, rd_discard;
    reg [31:0] rd_word;
    reg        rd_loaded, rd_half;
    reg        wr_overrun, rd_underrun;
    reg [15:0] even_pix;
    reg [15:0] src_frames;

    // Declared here rather than beside their always blocks below because
    // iverilog treats use-before-declaration as a hard error where Gowin only
    // warns (WARN EX3638) -- the divergence CLAUDE.md records, and the reason
    // this file carries `default_nettype none.
    reg        have_frame;   // a captured buffer has been SWAPPED to the reader
    reg        mode_real;    // the EFFECTIVE mux setting, resolved from mode_sel

    // ------------------------------------------------------------- SDRAM
    wire        sd_ready, sd_rvalid, sd_init;
    wire [31:0] sd_rdata;
    reg         sd_req, sd_we;
    reg  [20:0] sd_addr;
    reg  [31:0] sd_wdata;

    sdram_ctrl #(.CLK_HZ(CLK_HZ), .CAS_LAT(3)) u_sdram (
        .clk(clk_s), .rst_n(rst_n),
        .req(sd_req), .we(sd_we), .addr(sd_addr), .wdata(sd_wdata), .wmask(4'h0),
        .ready(sd_ready), .rdata(sd_rdata), .rvalid(sd_rvalid), .init_done(sd_init),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_ras_n(O_sdram_ras_n),
        .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq)
    );

    // The pixel the panel will latch at the next tick.
    wire [15:0] live_pix = rd_half ? rd_word[31:16] : rd_word[15:0];
    wire        want_pix = tg_tick && tg_nxt_de;

    // ---- swap and capture-arm events.
    //
    // These are mutually exclusive by construction, and the design depends on
    // it: `wr_active` implies `!wdone` (a capture only arms when no completed
    // frame is waiting, and wdone is only set as wr_active is cleared), so
    // ev_swap -- which needs wdone -- cannot coincide with ev_done, which needs
    // wr_active. Without that invariant the two would fight over `wdone` in the
    // same cycle and the later non-blocking assignment would silently win.
    // sim/targets/passthrough asserts the invariant on every clock.
    wire ev_swap = tg_frame && wdone;
    wire ev_done = src_frame_start && wr_active;
    wire ev_arm  = src_frame_start && !wr_active && !wdone;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            wf_wr <= 4'd0; wf_rd <= 4'd0;
            rf_wr <= 5'd0; rf_rd <= 5'd0;
            fetch_idx <= 21'd0; rd_pending <= 1'b0; rd_discard <= 1'b0;
            rd_word <= 32'd0; rd_loaded <= 1'b0; rd_half <= 1'b0;
            sd_req <= 1'b0; sd_we <= 1'b0; sd_addr <= 21'd0; sd_wdata <= 32'd0;
            wbuf <= 1'b0; rbuf <= 1'b1; wdone <= 1'b0; wr_active <= 1'b0;
            wr_overrun <= 1'b0; rd_underrun <= 1'b0;
            even_pix <= 16'd0; src_frames <= 16'd0; have_frame <= 1'b0;
        end else if (do_reset) begin
            wf_wr <= 4'd0; wf_rd <= 4'd0;
            rf_wr <= 5'd0; rf_rd <= 5'd0;
            fetch_idx <= 21'd0; rd_discard <= rd_pending;
            rd_loaded <= 1'b0; rd_half <= 1'b0;
            wbuf <= 1'b0; rbuf <= 1'b1; wdone <= 1'b0; wr_active <= 1'b0;
            wr_overrun <= 1'b0; rd_underrun <= 1'b0;
            src_frames <= 16'd0; have_frame <= 1'b0;
        end else begin
            // ---------------------------------------------------- buffer swap
            if (ev_swap) begin
                rbuf  <= wbuf;
                wbuf  <= ~wbuf;
                wdone <= 1'b0;
                // Sticky: from here on the reader's buffer holds a COMPLETE
                // captured frame. This is what AUTO waits for -- not
                // src_frames, which counts frames the writer has FINISHED, one
                // of which may still be sitting unswapped in wbuf. Switching
                // the mux on src_frames would present a buffer the panel has
                // not been given yet.
                have_frame <= 1'b1;
            end
            if (ev_done) begin
                wdone      <= 1'b1;
                wr_active  <= 1'b0;
                src_frames <= src_frames + 16'd1;
            end else if (ev_arm) begin
                wr_active <= 1'b1;
            end

            // ------------------------------------------------ writer: pack
            if (pix_valid && wr_active) begin
                if (!pix_x[0]) begin
                    even_pix <= pix;
                end else if (wf_full) begin
                    wr_overrun <= 1'b1;
                end else begin
                    wfifo_d[wf_wr[2:0]] <= {pix, even_pix};  // low half = even x
                    wfifo_a[wf_wr[2:0]] <= w_addr;
                    wf_wr <= wf_wr + 4'd1;
                end
            end

            // ------------------------------------ reader: restart each frame
            //
            // fetch_idx and the FIFO are reset at the PANEL's frame boundary,
            // so the read stream is re-aligned to the top of the buffer once
            // per frame by construction rather than by staying in step.
            //
            // rd_discard exists because an SDRAM read may still be in flight
            // when the frame boundary arrives: its data belongs to the previous
            // frame and must not be pushed into the freshly-emptied FIFO. An
            // in-flight request surviving a restart is exactly the class of bug
            // left open in Phase 2's frame_stream (see PROGRESS.md), so it is
            // handled explicitly here rather than assumed away.
            if (tg_frame) begin
                fetch_idx  <= 21'd0;
                rf_wr      <= 5'd0;
                rf_rd      <= 5'd0;
                rd_loaded  <= 1'b0;
                rd_half    <= 1'b0;
                if (rd_pending) rd_discard <= 1'b1;
            end

            // ------------------------------------------ reader: consume pixels
            // The read path runs in BOTH modes -- it fetches and consumes
            // regardless of what the mux selects -- so switching to REAL never
            // finds a cold FIFO and causes no transient. The underrun flag is
            // still qualified by mode and init, because the one window where an
            // underrun is real and meaningless is the ~200 us of SDRAM
            // initialisation at power-on: the panel is already scanning, no
            // data exists yet, and nothing is looking at it. Latching there
            // would leave the status report showing a fault for the rest of the
            // session.
            if (want_pix) begin
                if (!rd_loaded) begin
                    if (mode_real && sd_init) rd_underrun <= 1'b1;
                end else if (!rd_half) begin
                    rd_half <= 1'b1;
                end else begin
                    rd_half   <= 1'b0;
                    rd_loaded <= 1'b0;      // both halves used; reload
                end
            end

            if (!rd_loaded && !rf_empty && !tg_frame) begin
                rd_word   <= rfifo[rf_rd[3:0]];
                rf_rd     <= rf_rd + 5'd1;
                rd_loaded <= 1'b1;
            end

            // ------------------------------------------------ SDRAM arbiter
            //
            // The reader has priority. Its deadline is hard -- a word that is
            // late is a wrong pixel on the glass -- while the writer's FIFO can
            // absorb the wait and its data is not needed until the next swap.
            // At 36% combined utilisation neither can starve the other.
            if (sd_req && sd_ready) begin
                sd_req <= 1'b0;
                if (sd_we) wf_rd <= wf_rd + 4'd1;
            end else if (!sd_req && sd_init) begin
                if (!rd_pending && !rf_full && fetch_idx < FB_WORDS) begin
                    sd_req     <= 1'b1;
                    sd_we      <= 1'b0;
                    sd_addr    <= rbase + fetch_idx;
                    fetch_idx  <= fetch_idx + 21'd1;
                    rd_pending <= 1'b1;
                end else if (!wf_empty) begin
                    sd_req   <= 1'b1;
                    sd_we    <= 1'b1;
                    sd_addr  <= wfifo_a[wf_rd[2:0]];
                    sd_wdata <= wfifo_d[wf_rd[2:0]];
                end
            end

            if (sd_rvalid && rd_pending) begin
                rd_pending <= 1'b0;
                if (rd_discard) begin
                    rd_discard <= 1'b0;
                end else if (!rf_full) begin
                    rfifo[rf_wr[3:0]] <= sd_rdata;
                    rf_wr <= rf_wr + 5'd1;
                end
            end
        end
    end

    // -------------------------------------------------- effective mux setting
    //
    // AUTO resolves to REAL once a captured buffer has actually been swapped to
    // the reader; MOCK and REAL are absolute. The result is LATCHED AT THE
    // PANEL'S FRAME BOUNDARY, for the same reason the buffer swap is: changing
    // the pixel source mid-scan puts half a test pattern and half a captured
    // image in one frame. It is visible, it looks like a corruption bug, and it
    // costs one flip-flop to make impossible.
    //
    // The latch also buys a full frame of margin on the AUTO transition for
    // free. ev_swap sets have_frame on a tg_frame edge, so this block samples
    // the PRE-swap value on that same edge and only flips at the NEXT frame
    // boundary -- by which point the reader has been streaming the new buffer
    // for a whole frame. The mux can never reach a buffer mid-fill.
    wire want_real = (mode_sel == MODE_REAL) ||
                     ((mode_sel == MODE_AUTO) && have_frame);

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n)        mode_real <= 1'b0;
        else if (do_reset) mode_real <= 1'b0;
        else if (tg_frame) mode_real <= want_real;
    end

    // ------------------------------------------------------ pixel mux + pins
    wire [15:0] mock_pix = {pat_r, pat_g, pat_b};
    wire [15:0] real_pix = rd_loaded ? live_pix : 16'h0000;
    wire [15:0] src_pix  = mode_real ? real_pix : mock_pix;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            lcd_r <= 5'd0; lcd_g <= 6'd0; lcd_b <= 5'd0;
        end else if (tg_tick) begin
            lcd_r <= tg_nxt_de ? src_pix[15:11] : 5'd0;
            lcd_g <= tg_nxt_de ? src_pix[10:5]  : 6'd0;
            lcd_b <= tg_nxt_de ? src_pix[4:0]   : 5'd0;
        end
    end

    // ----------------------------------------------------------- backlight
    localparam [25:0] BL_DELAY_W = BL_DELAY_CYCLES;
    reg [25:0] bl_cnt;
    reg        bl_ready;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n)          begin bl_cnt <= 26'd0; bl_ready <= 1'b0; end
        else if (do_reset)   begin bl_cnt <= 26'd0; bl_ready <= 1'b0; end
        else if (!bl_ready) begin
            bl_cnt <= bl_cnt + 26'd1;
            if (bl_cnt >= BL_DELAY_W - 26'd1) bl_ready <= 1'b1;
        end
    end

    localparam [8:0] PWM_PRESCALE = 9'd422;   // 108 MHz / 422 / 256 = 999.6 Hz
    reg [8:0] pwm_pre;
    reg [7:0] pwm_cnt;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            pwm_pre <= 9'd0; pwm_cnt <= 8'd0;
        end else if (pwm_pre >= PWM_PRESCALE - 9'd1) begin
            pwm_pre <= 9'd0;
            pwm_cnt <= pwm_cnt + 8'd1;
        end else pwm_pre <= pwm_pre + 9'd1;
    end

    wire bl_on = bl_ready && (bl_duty != 8'd0);
    assign lcd_bl = bl_on && (pwm_cnt < bl_duty);

    // ------------------------------------------------------------- MONITOR
    // Panel timing measured off the design's own OUTPUT PINS, not reported from
    // the counters that generate them -- see the same block in
    // src/targets/lcd_panel/lcd_panel_top.v for why that distinction matters.
    reg        ck_d, hs_d, vs_d;
    reg [15:0] h_run, h_act, v_run, v_act;
    reg [15:0] h_total_m, h_active_m, v_total_m, v_active_m, frame_cnt;

    wire ck_rise = lcd_ck && !ck_d;
    wire hs_fall = !lcd_hs && hs_d;
    wire vs_fall = !lcd_vs && vs_d;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            ck_d <= 1'b1; hs_d <= 1'b0; vs_d <= 1'b0;
            h_run <= 16'd0; h_act <= 16'd0; v_run <= 16'd0; v_act <= 16'd0;
            h_total_m <= 16'd0; h_active_m <= 16'd0;
            v_total_m <= 16'd0; v_active_m <= 16'd0; frame_cnt <= 16'd0;
        end else begin
            ck_d <= lcd_ck; hs_d <= lcd_hs; vs_d <= lcd_vs;
            if (ck_rise) begin
                h_run <= h_run + 16'd1;
                if (lcd_de) h_act <= h_act + 16'd1;
            end
            if (hs_fall) begin
                h_total_m <= h_run;
                // Active lines only: 20 lines a frame are blanking, where 0 is
                // the correct count and a meaningless thing to report.
                if (h_act != 16'd0) h_active_m <= h_act;
                h_run <= 16'd0;
                h_act <= 16'd0;
                if (vs_fall) begin
                    v_total_m  <= v_run + 16'd1;
                    v_active_m <= v_act + ((h_act != 16'd0) ? 16'd1 : 16'd0);
                    v_run <= 16'd0; v_act <= 16'd0;
                    frame_cnt <= frame_cnt + 16'd1;
                end else begin
                    v_run <= v_run + 16'd1;
                    if (h_act != 16'd0) v_act <= v_act + 16'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------ reply TX
    wire      tx_ready;
    reg       tx_valid;
    wire      tx_fire = tx_ready && tx_valid;
    reg       sending;
    reg [4:0] hdr_i;

    reg [7:0] hdr_byte;
    always @(*) begin
        case (hdr_i)
            5'd0:  hdr_byte = HDR_MAGIC;
            5'd1:  hdr_byte = HDR_VERSION;
            5'd2:  hdr_byte = {1'b0, rd_underrun, wr_overrun, (frame_cnt != 16'd0),
                               bl_on, mode_real, sd_init, pll_lock};
            5'd3:  hdr_byte = {5'b0, pattern};
            5'd4:  hdr_byte = bl_duty;
            5'd5:  hdr_byte = {5'b0, have_frame, mode_sel};
            5'd6:  hdr_byte = h_total_m[7:0];
            5'd7:  hdr_byte = h_total_m[15:8];
            5'd8:  hdr_byte = h_active_m[7:0];
            5'd9:  hdr_byte = h_active_m[15:8];
            5'd10: hdr_byte = v_total_m[7:0];
            5'd11: hdr_byte = v_total_m[15:8];
            5'd12: hdr_byte = v_active_m[7:0];
            5'd13: hdr_byte = v_active_m[15:8];
            5'd14: hdr_byte = frame_cnt[7:0];
            5'd15: hdr_byte = frame_cnt[15:8];
            5'd16: hdr_byte = src_frames[7:0];
            5'd17: hdr_byte = src_frames[15:8];
            5'd18: hdr_byte = src_lines[7:0];
            5'd19: hdr_byte = src_lines[15:8];
            5'd20: hdr_byte = src_px_line[7:0];
            5'd21: hdr_byte = src_px_line[15:8];
            5'd22: hdr_byte = runts[7:0];
            default: hdr_byte = runts[15:8];
        endcase
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) tx_valid <= 1'b0;
        else        tx_valid <= tx_ready && sending;
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            sending <= 1'b0; hdr_i <= 5'd0;
        end else if (do_status) begin
            sending <= 1'b1; hdr_i <= 5'd0;
        end else if (sending && tx_fire) begin
            if (hdr_i == HDR_LAST) sending <= 1'b0;
            else                   hdr_i   <= hdr_i + 5'd1;
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk_s), .rst_n(rst_n),
        .data(hdr_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    // ---------------------------------------------------------------- LEDs
    reg [25:0] heartbeat;
    always @(posedge clk_s or negedge rst_n)
        if (!rst_n) heartbeat <= 26'd0; else heartbeat <= heartbeat + 26'd1;

    assign leds[0] = ~heartbeat[25];              // alive
    assign leds[1] = ~sd_init;                    // SDRAM initialised
    assign leds[2] = ~mode_real;                  // lit = REAL (passthrough)
    assign leds[3] = ~(src_frames != 16'd0);      // lit = the calculator is driving
    assign leds[4] = ~(frame_cnt  != 16'd0);      // lit = the panel is being driven
    assign leds[5] = ~(wr_overrun || rd_underrun);// lit = a FIFO has misbehaved
endmodule
`default_nettype wire
