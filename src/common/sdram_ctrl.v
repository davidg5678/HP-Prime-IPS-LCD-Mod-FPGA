`timescale 1ns/1ps
`default_nettype none
//
// SDR SDRAM controller for the die embedded in the GW2AR-18 package.
//
// 4 banks x 2048 rows x 256 columns x 32 bits = 64 Mbit / 8 MB, max 166 MHz.
// Full background, and the experiment that established the pin mapping, in
// docs/sdram.md.
//
// THE SDRAM PORT NAMES ARE LOAD-BEARING. `O_sdram_*` and `IO_sdram_dq` are
// recognised by the Gowin placer and bonded automatically to the in-package
// die: no pin constraints, and zero package pins consumed. Rename any of them
// and the tool silently treats it as ordinary I/O -- which, for 55 signals on a
// part with 53 free ones, shows up as ERROR (PA2024) rather than as anything
// resembling a naming problem. These names must survive all the way to the top
// level of a synthesised target, so every module between here and there passes
// them through unchanged.
//
// ACCESS MODEL: one word per request, always with auto-precharge, so a bank is
// never left open. That costs a row activation on every access -- about 8
// cycles per word, 13.5 MW/s, 54 MB/s at 108 MHz. Deliberate for a first
// controller: the Prime's bus produces 8.69 MB/s, so even this leaves 6x
// headroom, and "never leave a row open" removes every open-row hazard from
// the state space. Burst and open-row modes come later, measured against a
// working baseline rather than assumed.
//
// ADDRESS MAP: {bank[1:0], row[10:0], col[7:0]}. Sequential addresses stay in
// one row for 256 words before paying a row change. An alternative mapping,
// {row, bank, col}, would let consecutive pages land in different banks and
// allow the next row to be activated while the current one is still streaming
// -- worth doing if burst mode ever needs the bandwidth, and pointless before.
//
module sdram_ctrl #(
    parameter integer CLK_HZ = 108_000_000,
    parameter integer CAS_LAT = 3          // 2 or 3; the die supports both
) (
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------------------ user side
    input  wire        req,        // hold high until req && ready is seen
    input  wire        we,         // 1 = write, 0 = read
    input  wire [20:0] addr,       // word address {bank[1:0], row[10:0], col[7:0]}
    input  wire [31:0] wdata,
    input  wire [3:0]  wmask,      // per-byte, 1 = leave that byte alone
    // COMBINATIONAL, and it means "a request presented on THIS cycle will be
    // accepted" -- not "the controller was idle last cycle". Transfer happens
    // on any cycle where req && ready, so the requester must HOLD req until it
    // sees that, rather than pulsing it for one cycle.
    //
    // It was registered at first, and that is a race: the requester sees ready
    // a cycle late, and if a refresh falls due in the gap the controller takes
    // the refresh branch and the req pulse is silently dropped. A dropped write
    // skips a word; a dropped read hangs the requester forever waiting for
    // rvalid. Found by the sdram_selftest BIST deadlocking at word 22 -- the
    // unit testbench has too few accesses to collide with a 15 us refresh and
    // passed regardless.
    output wire        ready,
    output reg  [31:0] rdata,
    output reg         rvalid,     // 1-cycle pulse: rdata is valid
    output reg         init_done,

    // ----------------------------------------------------------- SDRAM side
    output wire        O_sdram_clk,
    output reg         O_sdram_cke,
    output reg         O_sdram_cs_n,
    output reg         O_sdram_ras_n,
    output reg         O_sdram_cas_n,
    output reg         O_sdram_wen_n,
    output reg  [3:0]  O_sdram_dqm,
    output reg  [10:0] O_sdram_addr,
    output reg  [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    // Cycle counts, rounded up, from the nanosecond figures in docs/sdram.md.
    // MHZ is exact for 108 MHz; the +999 is a ceiling.
    localparam integer MHZ    = CLK_HZ / 1_000_000;
    localparam integer C_RP   = (   20 * MHZ + 999) / 1000;   // 3
    localparam integer C_RCD  = (   20 * MHZ + 999) / 1000;   // 3
    localparam integer C_RC   = (   70 * MHZ + 999) / 1000;   // 8
    localparam integer C_RFC  = (   70 * MHZ + 999) / 1000;   // 8
    localparam integer C_MRD  = (   15 * MHZ + 999) / 1000;   // 2
    localparam integer C_INIT = (200000 * MHZ + 999) / 1000;  // 21600 = 200 us
    // Refresh every 15.625 us (4096 cycles / 64 ms). Asking slightly early
    // costs nothing at 6x bandwidth headroom and keeps margin against the
    // controller being busy when a refresh falls due.
    localparam integer C_REFI = (15000 * MHZ + 999) / 1000;   // 1620

    // {ras, cas, we} with cs low -- standard SDR SDRAM truth table.
    localparam [2:0] CMD_NOP = 3'b111, CMD_ACT = 3'b011, CMD_RD  = 3'b101,
                     CMD_WR  = 3'b100, CMD_PRE = 3'b010, CMD_REF = 3'b001,
                     CMD_LMR = 3'b000;

    // Mode register: burst length 1, sequential, CAS latency, standard mode,
    // programmed-length write bursts.
    localparam [10:0] MODE_REG = {2'b00, 1'b0, 2'b00,
                                  (CAS_LAT == 2) ? 3'b010 : 3'b011,
                                  1'b0, 3'b000};

    localparam [3:0] S_INIT_WAIT = 4'd0, S_INIT_PRE = 4'd1, S_INIT_REF = 4'd2,
                     S_INIT_MRD  = 4'd3, S_IDLE     = 4'd4, S_REFRESH  = 4'd5,
                     S_ACT       = 4'd6, S_RW       = 4'd7, S_WAIT     = 4'd8;

    reg [3:0]  state;
    reg [15:0] dly;          // generic countdown, in cycles
    reg [3:0]  ref_burst;    // AUTO REFRESHes remaining during init
    reg [11:0] ref_timer;
    reg        ref_due;

    reg        pend_we;
    reg [20:0] pend_addr;
    reg [31:0] pend_wdata;
    reg [3:0]  pend_wmask;
    reg [3:0]  rd_cnt;

    wire [1:0]  a_bank = pend_addr[20:19];
    wire [10:0] a_row  = pend_addr[18:8];
    wire [7:0]  a_col  = pend_addr[7:0];

    assign ready = (state == S_IDLE) && init_done && !ref_due;

    reg        dq_oe;
    reg [31:0] dq_out;
    assign IO_sdram_dq = dq_oe ? dq_out : 32'bz;

    // The die is clocked on the inverse of the controller clock, so every
    // registered output has half a cycle to settle before the die samples it.
    // This is the standard arrangement and it is also the thing most likely to
    // need adjusting on real silicon -- see the phase-offset note in
    // docs/sdram.md. In simulation it is exactly right by construction.
    assign O_sdram_clk = ~clk;

    task issue(input [2:0] c, input [1:0] bank, input [10:0] a);
        begin
            O_sdram_cs_n  <= 1'b0;
            {O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} <= c;
            O_sdram_ba    <= bank;
            O_sdram_addr  <= a;
        end
    endtask

    task nop;
        begin
            O_sdram_cs_n  <= 1'b1;
            {O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} <= CMD_NOP;
        end
    endtask

    // ------------------------------------------------------- refresh timer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_timer <= 12'd0;
            ref_due   <= 1'b0;
        end else if (!init_done) begin
            ref_timer <= 12'd0;
            ref_due   <= 1'b0;
        end else if (state == S_REFRESH) begin
            ref_timer <= 12'd0;
            ref_due   <= 1'b0;
        end else if (ref_timer >= C_REFI[11:0]) begin
            ref_due   <= 1'b1;
        end else begin
            ref_timer <= ref_timer + 12'd1;
        end
    end

    // ----------------------------------------------------------------- FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_INIT_WAIT;
            dly          <= C_INIT[15:0];
            ref_burst    <= 4'd8;
            rvalid       <= 1'b0;
            init_done    <= 1'b0;
            rdata        <= 32'd0;
            dq_oe        <= 1'b0;
            dq_out       <= 32'd0;
            rd_cnt       <= 4'd0;
            pend_we      <= 1'b0;
            pend_addr    <= 21'd0;
            pend_wdata   <= 32'd0;
            pend_wmask   <= 4'd0;
            O_sdram_cke  <= 1'b0;
            O_sdram_dqm  <= 4'hF;
            O_sdram_ba   <= 2'd0;
            O_sdram_addr <= 11'd0;
            O_sdram_cs_n <= 1'b1;
            {O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} <= CMD_NOP;
        end else begin
            rvalid <= 1'b0;
            dq_oe  <= 1'b0;
            nop;

            if (dly != 16'd0) begin
                dly <= dly - 16'd1;
            end

            case (state)
            // ---- initialisation: 200 us of NOP, precharge all, refreshes, LMR
            S_INIT_WAIT: begin
                O_sdram_cke <= 1'b1;
                O_sdram_dqm <= 4'hF;
                if (dly == 16'd0) begin
                    issue(CMD_PRE, 2'd0, 11'b100_0000_0000);  // A10 = precharge all
                    dly   <= C_RP[15:0];
                    state <= S_INIT_PRE;
                end
            end
            S_INIT_PRE: if (dly == 16'd0) begin
                issue(CMD_REF, 2'd0, 11'd0);
                dly       <= C_RFC[15:0];
                ref_burst <= ref_burst - 4'd1;
                state     <= S_INIT_REF;
            end
            S_INIT_REF: if (dly == 16'd0) begin
                if (ref_burst != 4'd0) begin
                    issue(CMD_REF, 2'd0, 11'd0);
                    dly       <= C_RFC[15:0];
                    ref_burst <= ref_burst - 4'd1;
                end else begin
                    issue(CMD_LMR, 2'd0, MODE_REG);
                    dly   <= C_MRD[15:0];
                    state <= S_INIT_MRD;
                end
            end
            S_INIT_MRD: if (dly == 16'd0) begin
                init_done <= 1'b1;
                state     <= S_IDLE;
            end

            // ---- steady state
            S_IDLE: begin
                O_sdram_dqm <= 4'h0;
                if (ref_due) begin
                    issue(CMD_REF, 2'd0, 11'd0);
                    dly   <= C_RFC[15:0];
                    state <= S_REFRESH;
                end else if (req) begin
                    pend_we    <= we;
                    pend_addr  <= addr;
                    pend_wdata <= wdata;
                    pend_wmask <= wmask;
                    // ACTIVATE has to wait a cycle for pend_addr to land; going
                    // straight there would drive the previous request's row.
                    dly        <= 16'd0;
                    state      <= S_ACT;
                end
            end
            S_REFRESH: if (dly == 16'd0) state <= S_IDLE;

            // ---- one access
            S_ACT: begin
                issue(CMD_ACT, a_bank, a_row);
                dly   <= C_RCD[15:0];
                state <= S_RW;
            end
            S_RW: if (dly == 16'd0) begin
                // A10 high = auto-precharge, so the bank closes itself and the
                // next ACTIVATE only has to respect tRC. Note the bit order:
                // A10 is the TOP bit of the 11-bit address, and the column
                // occupies the bottom 8. Writing {2'b00, 1'b1, col} instead
                // puts the flag on A8, which is inside the column field on a
                // 256-column part -- the bank then never closes, and the next
                // ACTIVATE lands on an already-open row.
                issue(pend_we ? CMD_WR : CMD_RD, a_bank,
                      {1'b1, 2'b00, a_col});
                if (pend_we) begin
                    dq_oe       <= 1'b1;
                    dq_out      <= pend_wdata;
                    O_sdram_dqm <= pend_wmask;
                end else begin
                    O_sdram_dqm <= 4'h0;
                end
                // tRC from the ACTIVATE dominates both tRP and the read
                // latency, so one wait covers every constraint.
                dly    <= (C_RC - C_RCD - 1);
                rd_cnt <= pend_we ? 4'd0 : (CAS_LAT[3:0] + 4'd1);
                state  <= S_WAIT;
            end
            S_WAIT: begin
                O_sdram_dqm <= 4'h0;
                if (rd_cnt != 4'd0) begin
                    rd_cnt <= rd_cnt - 4'd1;
                    if (rd_cnt == 4'd1) begin
                        rdata  <= IO_sdram_dq;
                        rvalid <= 1'b1;
                    end
                end
                if (dly == 16'd0 && rd_cnt <= 4'd1) state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
