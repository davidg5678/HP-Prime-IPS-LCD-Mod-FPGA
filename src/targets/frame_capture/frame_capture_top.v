`timescale 1ns/1ps
`default_nettype none
//
// Phase 2 enabler: capture a WHOLE FRAME of the HP Prime's LCD bus into SDRAM.
//
// la_capture holds 32768 oversampled samples -- 2.9 lines. A frame is 2.86 M
// oversampled samples, 88x more, so whole-frame work needs both more memory and
// a cheaper way of sampling. Both are solved here:
//
//   * Sampling is SYNCHRONOUS, one sample per DOTCLK rather than 8.1 per
//     DOTCLK. That is 13.29 MW/s instead of 108 MW/s, and it removes the runt
//     edges oversampling produces (see src/common/dotclk_sampler.v).
//   * Samples are 11 bits and pack TWO to a 32-bit word, giving 6.64 MW/s
//     against the ~10.8 MW/s sdram_ctrl delivers. That is what makes this fit
//     without burst mode; a frame is 688 KB and the 8 MB die holds eleven.
//
// Capture is armed by the host and starts on the next VSYNC falling edge, so a
// capture is frame-aligned by construction rather than by the host guessing.
//
// SAMPLE FORMAT. Each 11-bit sample is {D7..D0, DE, VSYNC, HSYNC}: bit 0 HSYNC,
// bit 1 VSYNC, bit 2 DE, bits 10..3 D0..D7. DOTCLK is not stored -- in
// synchronous capture every sample IS a DOTCLK, so recording it would waste a
// bit to say "yes" 352,499 times. Two samples per word:
//     word = {5'b0, sample_odd[10:0], 5'b0, sample_even[10:0]}
// so the even sample is bits 10..0 and the odd sample is bits 26..16.
//
// HOST PROTOCOL
//     0xAA        reset
//     0x41  'A'   arm: capture starts at the next VSYNC falling edge
//     0x53  'S'   status: the 12-byte report below
//     0x47  'G'+6 read window: start_word[31:0] then count[15:0], little-endian
//
// REPORT (12 bytes, little-endian; prefixes 'S' and 'G')
//     0     0xA5 magic
//     1     0x04 protocol version
//     2     status: bit0 pll_lock, bit1 sdram_init, bit2 armed, bit3 capturing,
//                   bit4 done, bit5 overrun
//     3     reserved
//     4..7  words captured
//     8..9  runt DOTCLK edges rejected
//     10..11 reply_count -- words following in THIS reply
//
// THE SDRAM PORT NAMES ARE LOAD-BEARING; see docs/sdram.md.
//
module frame_capture_top #(
    // One frame is 1361 DOTCLKs x 259 lines = 352,499 samples = 176,250 words.
    // Rounded up so an armed capture always contains a complete frame.
    parameter integer CAP_WORDS = 180_000
) (
    input  wire        clk,       // pin 4, 27 MHz
    input  wire        uart_rx,   // pin 70
    output wire        uart_tx,   // pin 69
    input  wire [11:0] probe,     // same channel map and pins as la_capture
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

    localparam [7:0] CMD_RESET = 8'hAA, CMD_ARM = 8'h41,
                     CMD_STATUS = 8'h53, CMD_READ = 8'h47;
    localparam [7:0] HDR_MAGIC = 8'hA5, HDR_VERSION = 8'h04;
    localparam [3:0] HDR_LAST  = 4'd11;

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

    reg        do_reset, do_arm, do_status, do_read;
    reg [2:0]  arg_left;
    reg [47:0] arg_sr;
    // do_read is a REGISTERED pulse, so these are read one cycle after the last
    // payload byte -- by which time arg_sr has already absorbed it. After six
    // bytes b0..b5 shifted in left-first, arg_sr holds
    //     [47:40]=b0 [39:32]=b1 [31:24]=b2 [23:16]=b3 [15:8]=b4 [7:0]=b5
    // Reading the positions as they stand DURING the last byte instead is an
    // off-by-one across every field, and shows up as a reply_count of zero.
    wire [31:0] rq_start = {arg_sr[23:16], arg_sr[31:24], arg_sr[39:32], arg_sr[47:40]};
    wire [15:0] rq_count = {arg_sr[7:0], arg_sr[15:8]};

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            do_reset <= 1'b0; do_arm <= 1'b0; do_status <= 1'b0; do_read <= 1'b0;
            arg_left <= 3'd0; arg_sr <= 48'd0;
        end else begin
            do_reset <= 1'b0; do_arm <= 1'b0; do_status <= 1'b0; do_read <= 1'b0;
            if (rx_valid) begin
                if (arg_left != 3'd0) begin
                    arg_sr   <= {arg_sr[39:0], rx_data};
                    arg_left <= arg_left - 3'd1;
                    if (arg_left == 3'd1) do_read <= 1'b1;
                end else case (rx_data)
                    CMD_RESET:  do_reset  <= 1'b1;
                    CMD_ARM:    do_arm    <= 1'b1;
                    CMD_STATUS: do_status <= 1'b1;
                    CMD_READ:   arg_left  <= 3'd6;
                    default: ;
                endcase
            end
        end
    end

    // --------------------------------------------------------- sample path
    wire [11:0] bus_s;
    sync2 #(.W(12)) u_sync (.clk(clk_s), .rst_n(rst_n), .d(probe), .q(bus_s));

    // la_capture's map is bit0 DOTCLK, 1 HSYNC, 2 VSYNC, 3 DE, 4..11 D0..D7.
    // Dropping DOTCLK leaves the 11 bits stored here.
    wire        s_dotclk = bus_s[0];
    wire [10:0] s_bus    = bus_s[11:1];
    wire        s_vsync  = bus_s[2];

    wire        smp_valid;
    wire [10:0] smp;
    wire [15:0] runts;
    dotclk_sampler u_smp (
        .clk(clk_s), .rst_n(rst_n), .arm(do_arm),
        .dotclk_s(s_dotclk), .bus_s(s_bus),
        .sample_valid(smp_valid), .sample(smp), .runts(runts)
    );

    reg vsync_d;
    always @(posedge clk_s or negedge rst_n)
        if (!rst_n) vsync_d <= 1'b1; else vsync_d <= s_vsync;
    wire vsync_fall = !s_vsync && vsync_d;

    // ------------------------------------------------------------- capture
    localparam [2:0] C_IDLE = 3'd0, C_WAIT = 3'd1, C_RUN = 3'd2, C_DONE = 3'd3,
                     C_DRAIN = 3'd4;
    reg [2:0]  cap;
    reg        phase;               // which half of the 32-bit word
    reg [10:0] even_smp;
    reg [31:0] words_cap;
    reg [20:0] wr_addr;
    reg        overrun;

    // A short elastic buffer between the sampler and the SDRAM. Words arrive
    // every ~16.3 cycles and an access takes ~10, so the average has plenty of
    // slack -- but a refresh stalls the controller for 8 cycles at arbitrary
    // moments, and without somewhere to put a word during one, a sample would
    // be lost. Eight entries is far more than the worst case; overrun is
    // reported rather than silently tolerated.
    localparam integer FD = 8;
    reg [31:0] fifo [0:FD-1];
    reg [3:0]  f_wr, f_rd;
    wire [3:0] f_cnt  = f_wr - f_rd;
    wire       f_full = (f_cnt >= FD[3:0]);
    wire       f_empty= (f_wr == f_rd);

    wire       sd_ready, sd_rvalid, sd_init;
    wire [31:0] sd_rdata;
    reg        sd_req, sd_we;
    reg [20:0] sd_addr;
    reg [31:0] sd_wdata;

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

    // ------------------------------------------------------------- drain TX
    wire       tx_ready;
    reg        tx_valid;
    wire       tx_fire = tx_ready && tx_valid;
    reg [3:0]  hdr_i;
    reg [1:0]  byte_i;
    reg        sending, in_body;
    reg [31:0] dr_word;
    reg [31:0] dr_addr;
    reg [15:0] dr_left, dr_len;
    reg        dr_pending;

    reg [7:0] hdr_byte;
    always @(*) begin
        case (hdr_i)
            4'd0:  hdr_byte = HDR_MAGIC;
            4'd1:  hdr_byte = HDR_VERSION;
            4'd2:  hdr_byte = {2'b00, overrun, cap == C_DONE, cap == C_RUN,
                               cap == C_WAIT, sd_init, pll_lock};
            4'd3:  hdr_byte = 8'h00;
            4'd4:  hdr_byte = words_cap[7:0];
            4'd5:  hdr_byte = words_cap[15:8];
            4'd6:  hdr_byte = words_cap[23:16];
            4'd7:  hdr_byte = words_cap[31:24];
            4'd8:  hdr_byte = runts[7:0];
            4'd9:  hdr_byte = runts[15:8];
            4'd10: hdr_byte = dr_len[7:0];
            default: hdr_byte = dr_len[15:8];
        endcase
    end

    wire [7:0] body_byte = (byte_i == 2'd0) ? dr_word[7:0]
                         : (byte_i == 2'd1) ? dr_word[15:8]
                         : (byte_i == 2'd2) ? dr_word[23:16]
                         :                    dr_word[31:24];
    wire [7:0] tx_byte = in_body ? body_byte : hdr_byte;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) tx_valid <= 1'b0;
        else        tx_valid <= tx_ready && sending && !(in_body && dr_pending);
    end

    // -------------------------------------------------------- main sequencer
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            cap <= C_IDLE; phase <= 1'b0; even_smp <= 11'd0; words_cap <= 32'd0;
            wr_addr <= 21'd0; overrun <= 1'b0;
            f_wr <= 4'd0; f_rd <= 4'd0;
            sd_req <= 1'b0; sd_we <= 1'b0; sd_addr <= 21'd0; sd_wdata <= 32'd0;
            sending <= 1'b0; in_body <= 1'b0; hdr_i <= 4'd0; byte_i <= 2'd0;
            dr_addr <= 32'd0; dr_left <= 16'd0; dr_len <= 16'd0;
            dr_word <= 32'd0; dr_pending <= 1'b0;
        end else begin
            if (sd_req && sd_ready) sd_req <= 1'b0;

            // ---- sampling and packing
            if (cap == C_RUN && smp_valid) begin
                phase <= ~phase;
                if (!phase) begin
                    even_smp <= smp;
                end else begin
                    if (f_full) begin
                        overrun <= 1'b1;
                    end else begin
                        fifo[f_wr[2:0]] <= {5'b0, smp, 5'b0, even_smp};
                        f_wr <= f_wr + 4'd1;
                    end
                end
            end

            // ---- draining the FIFO into SDRAM (only while capturing)
            if (cap == C_RUN && !f_empty && !sd_req && sd_init) begin
                sd_req   <= 1'b1;
                sd_we    <= 1'b1;
                sd_addr  <= wr_addr;
                sd_wdata <= fifo[f_rd[2:0]];
            end else if (cap == C_RUN && sd_req && sd_ready && sd_we) begin
                f_rd      <= f_rd + 4'd1;
                wr_addr   <= wr_addr + 21'd1;
                words_cap <= words_cap + 32'd1;
                if (words_cap + 32'd1 >= CAP_WORDS) cap <= C_DONE;
            end

            // ---- control
            if (do_reset) begin
                cap <= C_IDLE; phase <= 1'b0; words_cap <= 32'd0;
                wr_addr <= 21'd0; overrun <= 1'b0;
                f_wr <= 4'd0; f_rd <= 4'd0; sending <= 1'b0; in_body <= 1'b0;
            end else if (do_arm) begin
                cap <= C_WAIT; phase <= 1'b0; words_cap <= 32'd0;
                wr_addr <= 21'd0; overrun <= 1'b0;
                f_wr <= 4'd0; f_rd <= 4'd0;
            end else if (cap == C_WAIT && vsync_fall) begin
                cap <= C_RUN;
            end

            // ---- reply
            if (do_status || do_read) begin
                sending <= 1'b1; in_body <= 1'b0; hdr_i <= 4'd0; byte_i <= 2'd0;
                if (do_read) begin
                    dr_addr <= rq_start;
                    dr_len  <= rq_count;
                    dr_left <= rq_count;
                end else begin
                    dr_len  <= 16'd0;
                    dr_left <= 16'd0;
                end
                dr_pending <= 1'b0;
            end else if (sending && !in_body && tx_fire) begin
                if (hdr_i == HDR_LAST) begin
                    if (dr_left == 16'd0) begin
                        sending <= 1'b0;
                    end else begin
                        in_body    <= 1'b1;
                        byte_i     <= 2'd0;
                        dr_pending <= 1'b1;   // fetch the first word
                    end
                end else hdr_i <= hdr_i + 4'd1;
            end else if (sending && in_body && tx_fire) begin
                byte_i <= byte_i + 2'd1;
                if (byte_i == 2'd3) begin
                    dr_left <= dr_left - 16'd1;
                    dr_addr <= dr_addr + 32'd1;
                    if (dr_left == 16'd1) begin
                        sending <= 1'b0; in_body <= 1'b0;
                    end else begin
                        dr_pending <= 1'b1;
                    end
                end
            end

            // ---- read-back fetches, only when not capturing
            if (dr_pending && !sd_req && cap != C_RUN && sd_init) begin
                sd_req  <= 1'b1;
                sd_we   <= 1'b0;
                sd_addr <= dr_addr[20:0];
            end
            if (sd_rvalid && dr_pending) begin
                dr_word    <= sd_rdata;
                dr_pending <= 1'b0;
            end
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk_s), .rst_n(rst_n),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    // ---------------------------------------------------------------- LEDs
    reg [25:0] heartbeat;
    always @(posedge clk_s or negedge rst_n)
        if (!rst_n) heartbeat <= 26'd0; else heartbeat <= heartbeat + 26'd1;

    assign leds[0] = ~heartbeat[25];
    assign leds[1] = ~sd_init;
    assign leds[2] = ~(cap == C_WAIT);
    assign leds[3] = ~(cap == C_RUN);
    assign leds[4] = ~(cap == C_DONE);
    assign leds[5] = ~overrun;
endmodule
`default_nettype wire
