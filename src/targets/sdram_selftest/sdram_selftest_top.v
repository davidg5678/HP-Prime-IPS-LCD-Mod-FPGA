`timescale 1ns/1ps
`default_nettype none
//
// Built-in self test for the SDRAM embedded in the GW2AR-18 package.
//
// Writes an address-derived pattern over the whole 8 MB, reads it all back, and
// reports progress and any mismatches over the same 1 Mbaud BL616 UART link the
// rest of the project uses.
//
// This exists because simulation cannot answer the question that actually
// matters here. sdram_ctrl passes against a strict behavioural model, but the
// model has no notion of the one thing most likely to be wrong on silicon: the
// phase relationship between the clock the die sees and the data the FPGA
// drives. A controller with the wrong clock phase simulates perfectly and reads
// garbage. Only real memory can say.
//
// THE SDRAM PORT NAMES ARE LOAD-BEARING and must appear on the top level
// exactly as written -- Gowin's placer matches on them to bond the ports to the
// in-package die, with no pin constraints and no package pins consumed. See
// docs/sdram.md for the experiment that established this.
//
// HOST PROTOCOL
//     0xAA        reset: abort any test, return to idle
//     0x54  'T'   start a full-memory test
//     0x53  'S'   status: reply with the 11-byte report below
//
// REPORT (11 bytes, little-endian)
//     0     0xA5 magic
//     1     0x03 protocol version
//     2     status: bit0 init_done, bit1 running, bit2 done, bit3 failed,
//                   bit4 pll_lock
//     3..6  words verified so far
//     7..10 mismatches
//
module sdram_selftest_top #(
    // Words to test. The full part is 4 banks x 2048 rows x 256 cols = 2^21
    // words = 8 MB; at roughly 8 cycles per access and two passes that is about
    // 310 ms at 108 MHz. The testbench shrinks it.
    parameter integer TEST_WORDS = 21'h1FFFFF + 1
) (
    input  wire        clk,       // pin 4, 27 MHz
    input  wire        uart_rx,   // pin 70
    output wire        uart_tx,   // pin 69
    output wire [5:0]  leds,      // pins 15-20, active low

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

    localparam [7:0] CMD_RESET  = 8'hAA;
    localparam [7:0] CMD_TEST   = 8'h54;  // 'T'
    localparam [7:0] CMD_STATUS = 8'h53;  // 'S'
    localparam [7:0] HDR_MAGIC = 8'hA5, HDR_VERSION = 8'h03;
    localparam [3:0] HDR_LAST  = 4'd10;

    // ------------------------------------------------------------ clocking
    wire clk_s, pll_lock;
    pll_27_108 u_pll (.clkin(clk), .clkout(clk_s), .lock(pll_lock));

    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;
    always @(posedge clk_s) begin
        if (!pll_lock) begin
            por_cnt <= 16'd0;
            rst_n   <= 1'b0;
        end else begin
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

    reg do_reset, do_test, do_status;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            do_reset <= 1'b0; do_test <= 1'b0; do_status <= 1'b0;
        end else begin
            do_reset <= 1'b0; do_test <= 1'b0; do_status <= 1'b0;
            if (rx_valid) case (rx_data)
                CMD_RESET:  do_reset  <= 1'b1;
                CMD_TEST:   do_test   <= 1'b1;
                CMD_STATUS: do_status <= 1'b1;
                default: ;
            endcase
        end
    end

    // -------------------------------------------------------- SDRAM + BIST
    wire        sd_ready, sd_rvalid, sd_init_done;
    wire [31:0] sd_rdata;
    reg         sd_req, sd_we;
    reg  [20:0] sd_addr;
    reg  [31:0] sd_wdata;

    sdram_ctrl #(.CLK_HZ(CLK_HZ), .CAS_LAT(3)) u_sdram (
        .clk(clk_s), .rst_n(rst_n),
        .req(sd_req), .we(sd_we), .addr(sd_addr), .wdata(sd_wdata), .wmask(4'h0),
        .ready(sd_ready), .rdata(sd_rdata), .rvalid(sd_rvalid),
        .init_done(sd_init_done),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_ras_n(O_sdram_ras_n),
        .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq)
    );

    // Address-derived pattern. The shift makes every address bit affect the
    // low word, so a stuck or swapped address line shows up as a data
    // mismatch rather than as a silently aliased write.
    function [31:0] pattern(input [20:0] a);
        pattern = ({11'd0, a} ^ ({11'd0, a} << 11)) ^ 32'h5A5A_A5A5;
    endfunction

    localparam [1:0] B_IDLE = 2'd0, B_WRITE = 2'd1, B_READ = 2'd2, B_DONE = 2'd3;
    reg [1:0]  bist;
    reg [20:0] bist_addr;
    reg [31:0] words_ok, errcount;
    reg        rd_outstanding;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            bist <= B_IDLE; bist_addr <= 21'd0; words_ok <= 32'd0;
            errcount <= 32'd0; sd_req <= 1'b0; sd_we <= 1'b0;
            sd_addr <= 21'd0; sd_wdata <= 32'd0; rd_outstanding <= 1'b0;
        end else begin
            // sd_req is NOT cleared unconditionally here: it is held until the
            // cycle where sd_req && sd_ready, which is the only unambiguous
            // moment the controller accepts. Pulsing it for one cycle instead
            // loses the request whenever a refresh falls due in the same cycle
            // -- silently skipping a write, or hanging forever on a read.
            if (sd_req && sd_ready) sd_req <= 1'b0;
            if (do_reset) begin
                bist <= B_IDLE; bist_addr <= 21'd0; sd_req <= 1'b0;
                words_ok <= 32'd0; errcount <= 32'd0; rd_outstanding <= 1'b0;
            end else case (bist)
            B_IDLE: if (do_test && sd_init_done) begin
                bist <= B_WRITE; bist_addr <= 21'd0;
                words_ok <= 32'd0; errcount <= 32'd0;
            end
            B_WRITE: begin
                if (!sd_req) begin
                    sd_req   <= 1'b1;
                    sd_we    <= 1'b1;
                    sd_addr  <= bist_addr;
                    sd_wdata <= pattern(bist_addr);
                end else if (sd_ready) begin
                    // Accepted this cycle -- advance.
                    if (bist_addr == TEST_WORDS - 1) begin
                        bist <= B_READ; bist_addr <= 21'd0;
                    end else begin
                        bist_addr <= bist_addr + 21'd1;
                    end
                end
            end
            B_READ: begin
                if (!sd_req && !rd_outstanding) begin
                    sd_req  <= 1'b1;
                    sd_we   <= 1'b0;
                    sd_addr <= bist_addr;
                end else if (sd_req && sd_ready) begin
                    rd_outstanding <= 1'b1;
                end
                if (sd_rvalid) begin
                    rd_outstanding <= 1'b0;
                    if (sd_rdata == pattern(bist_addr)) words_ok <= words_ok + 32'd1;
                    else                                errcount <= errcount + 32'd1;
                    if (bist_addr == TEST_WORDS - 1) bist <= B_DONE;
                    else                             bist_addr <= bist_addr + 21'd1;
                end
            end
            B_DONE: ;
            default: bist <= B_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------ report TX
    wire       tx_ready;
    reg        tx_valid;
    wire       tx_fire = tx_ready && tx_valid;
    reg [3:0]  hdr_i;
    reg        sending;

    reg [7:0] hdr_byte;
    always @(*) begin
        case (hdr_i)
            4'd0:    hdr_byte = HDR_MAGIC;
            4'd1:    hdr_byte = HDR_VERSION;
            4'd2:    hdr_byte = {3'b000, pll_lock, (bist == B_DONE) && (errcount != 0),
                                 bist == B_DONE, bist != B_IDLE && bist != B_DONE,
                                 sd_init_done};
            4'd3:    hdr_byte = words_ok[7:0];
            4'd4:    hdr_byte = words_ok[15:8];
            4'd5:    hdr_byte = words_ok[23:16];
            4'd6:    hdr_byte = words_ok[31:24];
            4'd7:    hdr_byte = errcount[7:0];
            4'd8:    hdr_byte = errcount[15:8];
            4'd9:    hdr_byte = errcount[23:16];
            default: hdr_byte = errcount[31:24];
        endcase
    end

    // Registering tx_valid off tx_ready, exactly as in la_capture: uart_tx
    // latches on any cycle where state==IDLE && valid, which can precede its
    // ready output by a cycle, so a level-held valid would be consumed without
    // this FSM seeing tx_fire and the byte would go out twice.
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) tx_valid <= 1'b0;
        else        tx_valid <= tx_ready && sending;
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            sending <= 1'b0; hdr_i <= 4'd0;
        end else if (do_status) begin
            sending <= 1'b1; hdr_i <= 4'd0;
        end else if (tx_fire && sending) begin
            if (hdr_i == HDR_LAST) sending <= 1'b0;
            else                   hdr_i   <= hdr_i + 4'd1;
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk_s), .rst_n(rst_n),
        .data(hdr_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    // ---------------------------------------------------------------- LEDs
    reg [25:0] heartbeat;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) heartbeat <= 26'd0;
        else        heartbeat <= heartbeat + 26'd1;
    end

    assign leds[0] = ~heartbeat[25];
    assign leds[1] = ~sd_init_done;
    assign leds[2] = ~(bist == B_WRITE || bist == B_READ);
    assign leds[3] = ~(bist == B_DONE);
    assign leds[4] = ~((bist == B_DONE) && (errcount != 0));
    assign leds[5] = ~pll_lock;
endmodule
`default_nettype wire
