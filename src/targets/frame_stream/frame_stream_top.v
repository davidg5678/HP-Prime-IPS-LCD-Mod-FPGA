`timescale 1ns/1ps
`default_nettype none
//
// Live streaming of the HP Prime's screen: capture a frame, RLE-encode it into
// SDRAM, send it, repeat.
//
// WHY IT IS SHAPED THIS WAY -- every part of it follows from measurement:
//
//   * The Prime produces a frame every 26.5 ms. RLE-encoded that is about
//     1.8 MB/s, against a link that carries 98 KB/s. Streaming every frame is
//     19x too fast, so frames are SKIPPED, not queued: capture one, send it,
//     and only then look for the next VSYNC.
//   * A frame arrives in 26.5 ms but takes ~500 ms to send, so the compressed
//     frame has to be buffered while it goes out. A typical frame is 50 KB and
//     a busy one is far more; BSRAM is 104 KB in total. It goes in SDRAM --
//     which is what the SDRAM was built for.
//   * RLE gives 4.6x on a real captured frame (230,400 -> 49,864 bytes),
//     because 74% of a real screen was one flat white. That is the difference
//     between 0.43 and 2.0 frames per second.
//   * The link stays at 1 Mbaud. Measured: 3 Mbaud gives no more throughput
//     (per-request latency dominates at ~79 KB/s either way) and a continuous
//     push at 3 Mbaud loses 65% of its bytes because the FPGA outruns the host.
//     At 1 Mbaud the FPGA is the slower party, so a continuous push cannot
//     overrun anything and needs no flow control at all.
//
// WIRE FORMAT. A byte stream, self-framing because an RLE count is never zero:
//     00 01                  start of frame
//     00 02                  the previous frame was truncated (encoder overran)
//     NN RR GG BB            a run of NN pixels of colour RR,GG,BB  (NN = 1..255)
// The host fills a linear pixel buffer and wraps at 320; runs may span line
// ends, which is why the marker rather than position is what resynchronises.
//
// COMMANDS (only honoured while idle, so they cannot corrupt a stream)
//     0xAA        stop and reset
//     0x52  'R'   start streaming, continuously, until stopped
//     0x53  'S'   status: the 8-byte report below
//
// REPORT (8 bytes, little-endian)
//     0 0xA5 magic, 1 0x05 version
//     2 status: bit0 pll_lock, bit1 sdram_init, bit2 streaming, bit3 truncated
//     3 reserved
//     4..7 pixels encoded in the last frame
//
// THE SDRAM PORT NAMES ARE LOAD-BEARING; see docs/sdram.md.
//
module frame_stream_top #(
    // Ceiling on the compressed size of one frame, in 32-bit words. 64K words
    // is 256 KB -- five times a typical frame, and the SDRAM has room for far
    // more. A frame that exceeds it is truncated and flagged rather than
    // allowed to run into the next one.
    parameter integer MAX_WORDS = 65536
) (
    input  wire        clk,
    input  wire        uart_rx,
    output wire        uart_tx,
    input  wire [11:0] probe,
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

    localparam [7:0] CMD_STOP = 8'hAA, CMD_RUN = 8'h52, CMD_STATUS = 8'h53;
    localparam [7:0] HDR_MAGIC = 8'hA5, HDR_VERSION = 8'h05;

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

    reg do_stop, do_run, do_status;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin do_stop <= 1'b0; do_run <= 1'b0; do_status <= 1'b0; end
        else begin
            do_stop <= 1'b0; do_run <= 1'b0; do_status <= 1'b0;
            if (rx_valid) case (rx_data)
                CMD_STOP:   do_stop   <= 1'b1;
                CMD_RUN:    do_run    <= 1'b1;
                CMD_STATUS: do_status <= 1'b1;
                default: ;
            endcase
        end
    end

    // State encoding is declared here, ahead of the VSYNC tracker that uses
    // it. Declaring it further down where the FSM lives built cleanly under
    // GowinSynthesis and was rejected outright by iverilog -- the same
    // declare-before-use divergence CLAUDE.md records for WARN (EX3638).
    localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_CAP = 3'd2,
                     S_FLUSH = 3'd3, S_SEND = 3'd4, S_STATUS = 3'd5,
                     S_PAD = 3'd6, S_DRAIN = 3'd7;

    reg [2:0]  st;

    // --------------------------------------------------------- sample path
    wire [11:0] bus_s;
    sync2 #(.W(12)) u_sync (.clk(clk_s), .rst_n(rst_n), .d(probe), .q(bus_s));
    wire        s_dotclk = bus_s[0];
    wire [10:0] s_bus    = bus_s[11:1];
    wire        s_vsync  = bus_s[2];

    reg  st_run, cap_on;
    wire        smp_valid;
    wire [10:0] smp;
    wire [15:0] runts;
    dotclk_sampler u_smp (
        .clk(clk_s), .rst_n(rst_n), .arm(do_run),
        .dotclk_s(s_dotclk), .bus_s(s_bus),
        .sample_valid(smp_valid), .sample(smp), .runts(runts)
    );

    reg vsync_d, vsync_seen_high;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin vsync_d <= 1'b1; vsync_seen_high <= 1'b0; end
        else begin
            vsync_d <= s_vsync;
            if (st != S_WAIT)     vsync_seen_high <= 1'b0;
            else if (s_vsync)     vsync_seen_high <= 1'b1;
        end
    end
    wire vsync_fall = !s_vsync && vsync_d;

    reg         frame_start;
    wire        rle_busy;
    wire        rle_valid;
    wire [7:0]  rle_byte;
    wire [31:0] rle_pixels;
    pixel_rle u_rle (
        .clk(clk_s), .rst_n(rst_n),
        .smp_valid(smp_valid), .smp(smp),
        .frame_start(frame_start), .enable(cap_on),
        .byte_valid(rle_valid), .byte_out(rle_byte), .pixels(rle_pixels),
        .busy(rle_busy)
    );

    // ------------------------------------------------------------- storage
    wire        sd_ready, sd_rvalid, sd_init;
    wire [31:0] sd_rdata;
    reg         sd_req, sd_we;
    reg [20:0]  sd_addr;
    reg [31:0]  sd_wdata;

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

    // Byte -> word assembly on the way in. RLE bytes arrive in bursts of four
    // at most once per pixel (3 DOTCLKs, ~24 cycles), and an SDRAM word write
    // takes ~10, so the average has plenty of slack; the FIFO covers refresh
    // stalls.
    localparam integer FD = 8;
    reg [31:0] fifo [0:FD-1];
    reg [3:0]  f_wr, f_rd;
    wire [3:0] f_cnt   = f_wr - f_rd;
    wire       f_full  = (f_cnt >= FD[3:0]);
    wire       f_empty = (f_wr == f_rd);

    reg [1:0]  bpos;
    reg [31:0] bword;
    reg [20:0] wr_addr;
    reg [20:0] frame_words;
    reg        truncated;

    // ---------------------------------------------------------------- FSM

    // Pad word for a partial tail, with the never-written bytes explicitly
    // zeroed rather than left holding whatever the previous word had.
    wire [31:0] pad_word = (bpos == 2'd1) ? {24'd0, bword[7:0]}
                         : (bpos == 2'd2) ? {16'd0, bword[15:0]}
                         :                  { 8'd0, bword[23:0]};
    reg [20:0] rd_addr;
    reg [31:0] send_word;
    reg [1:0]  send_byte_i;
    reg [2:0]  mark_i;
    reg        in_mark, fetch_pending;
    reg [3:0]  hdr_i;

    wire       tx_ready;
    reg        tx_valid;
    wire       tx_fire = tx_ready && tx_valid;

    reg [7:0] hdr_byte;
    always @(*) begin
        case (hdr_i)
            4'd0: hdr_byte = HDR_MAGIC;
            4'd1: hdr_byte = HDR_VERSION;
            4'd2: hdr_byte = {4'b0000, truncated, st != S_IDLE, sd_init, pll_lock};
            4'd3: hdr_byte = 8'h00;
            4'd4: hdr_byte = rle_pixels[7:0];
            4'd5: hdr_byte = rle_pixels[15:8];
            4'd6: hdr_byte = rle_pixels[23:16];
            default: hdr_byte = rle_pixels[31:24];
        endcase
    end

    wire [7:0] mark_byte = (mark_i == 3'd0) ? 8'h00
                         : truncated        ? 8'h02 : 8'h01;
    wire [7:0] body_byte = (send_byte_i == 2'd0) ? send_word[7:0]
                         : (send_byte_i == 2'd1) ? send_word[15:8]
                         : (send_byte_i == 2'd2) ? send_word[23:16]
                         :                         send_word[31:24];
    wire [7:0] tx_byte = (st == S_STATUS) ? hdr_byte
                       : in_mark          ? mark_byte : body_byte;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) tx_valid <= 1'b0;
        else tx_valid <= tx_ready &&
                         ((st == S_STATUS) ||
                          (st == S_SEND && (in_mark || !fetch_pending)));
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; st_run <= 1'b0; cap_on <= 1'b0; frame_start <= 1'b0;
            sd_req <= 1'b0; sd_we <= 1'b0; sd_addr <= 21'd0; sd_wdata <= 32'd0;
            f_wr <= 4'd0; f_rd <= 4'd0; bpos <= 2'd0; bword <= 32'd0;
            wr_addr <= 21'd0; frame_words <= 21'd0; truncated <= 1'b0;
            rd_addr <= 21'd0; send_word <= 32'd0; send_byte_i <= 2'd0;
            mark_i <= 3'd0; in_mark <= 1'b0; fetch_pending <= 1'b0; hdr_i <= 4'd0;
        end else begin
            frame_start <= 1'b0;
            if (sd_req && sd_ready) sd_req <= 1'b0;

            // ---- RLE bytes -> 32-bit words -> FIFO
            // S_FLUSH as well as S_CAP: `frame_start` flushes the run still
            // open in the encoder, and those four bytes arrive one cycle after
            // the state has already left S_CAP. Accepting only in S_CAP threw
            // the last run of every frame away -- one pixel short, every time.
            if ((st == S_CAP || st == S_FLUSH) && rle_valid) begin
                case (bpos)
                    2'd0: bword[7:0]   <= rle_byte;
                    2'd1: bword[15:8]  <= rle_byte;
                    2'd2: bword[23:16] <= rle_byte;
                    default: begin
                        if (f_full || wr_addr >= MAX_WORDS[20:0]) truncated <= 1'b1;
                        else begin
                            fifo[f_wr[2:0]] <= {rle_byte, bword[23:0]};
                            f_wr <= f_wr + 4'd1;
                        end
                    end
                endcase
                bpos <= bpos + 2'd1;
            end

            // ---- FIFO -> SDRAM, during capture and the flush that follows
            if ((st == S_CAP || st == S_FLUSH || st == S_PAD || st == S_DRAIN)
                && !f_empty && !sd_req && sd_init) begin
                sd_req <= 1'b1; sd_we <= 1'b1;
                sd_addr <= wr_addr; sd_wdata <= fifo[f_rd[2:0]];
            end else if ((st == S_CAP || st == S_FLUSH || st == S_PAD || st == S_DRAIN)
                         && sd_req && sd_ready && sd_we) begin
                f_rd    <= f_rd + 4'd1;
                wr_addr <= wr_addr + 21'd1;
            end

            case (st)
            S_IDLE: begin
                cap_on <= 1'b0;
                if (do_run && sd_init) begin
                    st_run <= 1'b1; truncated <= 1'b0; st <= S_WAIT;
                end else if (do_status) begin
                    hdr_i <= 4'd0; st <= S_STATUS;
                end
            end
            S_STATUS: if (tx_fire) begin
                if (hdr_i == 4'd7) st <= S_IDLE; else hdr_i <= hdr_i + 4'd1;
            end

            // Require VSYNC to have been observed HIGH before accepting a
            // falling edge. A send ends at an arbitrary point in the frame,
            // quite possibly inside the VSYNC pulse itself, and without this
            // guard the state machine can latch onto the tail of the pulse it
            // is already sitting in and start a capture that ends a few
            // hundred microseconds later at the real edge -- a frame with
            // almost no pixels in it.
            S_WAIT: if (vsync_seen_high && vsync_fall) begin
                frame_start <= 1'b1;
                cap_on      <= 1'b1;
                wr_addr     <= 21'd0; f_wr <= 4'd0; f_rd <= 4'd0;
                bpos        <= 2'd0;
                bword       <= 32'd0;
                // The send leaves a fetch in flight; carrying it into the
                // capture would collide with the write path's use of sd_req.
                fetch_pending <= 1'b0;
                in_mark       <= 1'b0;
                st          <= S_CAP;
            end

            // One VSYNC to the next is exactly one frame.
            S_CAP: if (vsync_fall) begin
                cap_on      <= 1'b0;
                frame_start <= 1'b1;   // flushes the run still open in pixel_rle
                st          <= S_FLUSH;
            end

            // Let the encoder's last run and the FIFO reach SDRAM before
            // reading any of it back.
            // Three things must finish, IN SEPARATE CYCLES: the encoder stops
            // producing bytes, any partial word is padded and pushed, and the
            // FIFO reaches SDRAM.
            //
            // The pad step gets its own state because bpos wraps 3->0 by
            // non-blocking assignment. Checking it in the same cycle the
            // encoder's last byte completed a word reads the stale 3, fires the
            // pad branch, and writes fifo[f_wr] a second time -- Verilog takes
            // the later assignment, so a correct word was being replaced by a
            // zero-padded one. It showed up as exactly one wrong byte at the
            // end of every frame.
            S_FLUSH: if (!rle_busy) st <= S_PAD;
            S_PAD: begin
                if (bpos != 2'd0) begin
                    if (!f_full && wr_addr < MAX_WORDS[20:0]) begin
                        fifo[f_wr[2:0]] <= pad_word;
                        f_wr <= f_wr + 4'd1;
                    end else truncated <= 1'b1;
                    bpos <= 2'd0;
                end
                st <= S_DRAIN;
            end
            S_DRAIN: if (f_empty && !sd_req) begin
                frame_words   <= wr_addr;
                rd_addr       <= 21'd0;
                send_byte_i   <= 2'd0;
                mark_i        <= 3'd0;
                in_mark       <= 1'b1;
                fetch_pending <= 1'b1;
                st            <= S_SEND;
            end

            S_SEND: begin
                if (in_mark && tx_fire) begin
                    if (mark_i == 3'd1) begin
                        in_mark   <= 1'b0;
                        truncated <= 1'b0;
                        if (frame_words == 21'd0)
                            st <= st_run ? S_WAIT : S_IDLE;
                    end else mark_i <= mark_i + 3'd1;
                end else if (!in_mark && tx_fire) begin
                    send_byte_i <= send_byte_i + 2'd1;
                    if (send_byte_i == 2'd3) begin
                        rd_addr <= rd_addr + 21'd1;
                        if (rd_addr + 21'd1 >= frame_words)
                            st <= st_run ? S_WAIT : S_IDLE;
                        else
                            fetch_pending <= 1'b1;
                    end
                end
                if (fetch_pending && !sd_req && sd_init) begin
                    sd_req <= 1'b1; sd_we <= 1'b0; sd_addr <= rd_addr;
                end
                if (sd_rvalid && fetch_pending) begin
                    send_word     <= sd_rdata;
                    fetch_pending <= 1'b0;
                end
            end
            default: st <= S_IDLE;
            endcase

            if (do_stop) begin
                st <= S_IDLE; st_run <= 1'b0; cap_on <= 1'b0;
                in_mark <= 1'b0; fetch_pending <= 1'b0;
            end
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk_s), .rst_n(rst_n),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    reg [25:0] heartbeat;
    always @(posedge clk_s or negedge rst_n)
        if (!rst_n) heartbeat <= 26'd0; else heartbeat <= heartbeat + 26'd1;

    assign leds[0] = ~heartbeat[25];
    assign leds[1] = ~sd_init;
    assign leds[2] = ~(st == S_CAP);
    assign leds[3] = ~(st == S_SEND);
    assign leds[4] = ~truncated;
    assign leds[5] = ~pll_lock;
endmodule
`default_nettype wire
