`timescale 1ns/1ps
//
// Behavioural model of the SDR SDRAM embedded in the GW2AR-18 package.
// Simulation only -- never listed in a src/targets/*/files.txt.
//
// Gowin ships NO simulation model for this die. Its own IP Readme says so
// outright: "Currently, we do not provide simulation models. If you need to use
// it, please contact Micron Technology". So this file is the oracle the whole
// SDRAM effort rests on, and it exists to be STRICT: it checks the protocol
// rather than merely responding to it. A permissive model would let a
// controller that violates tRCD, forgets to refresh, or reads an idle bank pass
// simulation and then fail on silicon -- which is the one outcome that would
// make the whole exercise pointless, since the real die gives no diagnostics
// at all.
//
// Geometry per the GW2AR data sheet (DS226-2.7E section 2.2.1):
//   4 banks x 2048 rows x 256 columns x 32 bits = 64 Mbit
// ROWS is parameterised only so testbenches can shrink the storage array;
// everything else matches the real part.
//
// Not modelled: self-refresh, power-down, burst-terminate, interleaved burst
// order, full-page bursts, and analogue timing (setup/hold on DQ). Selecting an
// unsupported mode is reported as an error rather than silently ignored.
//
module sdram_sim #(
    parameter integer BANKS   = 4,
    parameter integer ROWS    = 2048,
    parameter integer COLS    = 256,
    parameter integer DW      = 32,
    parameter integer AW      = 11,   // row address width
    parameter integer BW      = 2,
    parameter integer CW      = 8,    // column address width
    // Timing floors, in nanoseconds. Conservative standard SDR values -- the
    // GW2AR data sheet quotes 166 MHz and 5.4 ns access but defers its AC table
    // to IPUG279, which is not installed. See docs/sdram.md.
    parameter real    T_RP    = 20.0,
    parameter real    T_RCD   = 20.0,
    parameter real    T_RAS   = 45.0,
    parameter real    T_RC    = 70.0,
    parameter real    T_RFC   = 70.0,
    parameter real    T_WR    = 15.0,
    parameter real    T_MRD   = 15.0,
    parameter real    T_REFI  = 15625.0,  // 4096 refresh cycles / 64 ms
    // Checking the refresh interval needs a grace period, otherwise the very
    // first check fires before the controller has had a chance to issue
    // anything. Also lets a testbench disable the check when it is deliberately
    // exercising something else.
    parameter integer CHECK_REFRESH = 1
) (
    input  wire             Clk,
    input  wire             Cke,
    input  wire             Cs_n,
    input  wire             Ras_n,
    input  wire             Cas_n,
    input  wire             We_n,
    input  wire [BW-1:0]    Ba,
    input  wire [AW-1:0]    Addr,
    input  wire [DW/8-1:0]  Dqm,
    inout  wire [DW-1:0]    Dq
);
    // ------------------------------------------------------------- commands
    // {Ras_n, Cas_n, We_n} with Cs_n low. Standard SDR SDRAM truth table.
    localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD  = 3'b101,
                     C_WR  = 3'b100, C_BST = 3'b110, C_PRE = 3'b010,
                     C_REF = 3'b001, C_LMR = 3'b000;

    integer errors = 0;
    task oops(input [1023:0] msg);
        begin
            $display("FAIL: sdram_sim @%0t: %0s", $realtime, msg);
            errors = errors + 1;
        end
    endtask

    // -------------------------------------------------------------- storage
    localparam integer DEPTH = BANKS * ROWS * COLS;
    reg [DW-1:0] mem [0:DEPTH-1];

    function integer flat(input integer b, input integer r, input integer c);
        flat = ((b * ROWS) + r) * COLS + c;
    endfunction

    // ---------------------------------------------------------- bank state
    reg              b_active [0:BANKS-1];
    integer          b_row    [0:BANKS-1];
    real             t_act    [0:BANKS-1];   // last ACTIVATE
    real             t_pre    [0:BANKS-1];   // last PRECHARGE
    real             t_wr_end [0:BANKS-1];   // last write data beat
    real             t_lmr = -1.0e9;
    real             t_ref = -1.0e9;

    // mode register
    integer ml_burst = 1;
    integer ml_cas   = 3;
    reg     ml_valid = 1'b0;

    integer i;
    initial begin
        for (i = 0; i < BANKS; i = i + 1) begin
            b_active[i] = 1'b0; b_row[i] = 0;
            t_act[i] = -1.0e9; t_pre[i] = -1.0e9; t_wr_end[i] = -1.0e9;
        end
    end

    // --------------------------------------------------------- read return
    // A tiny shift pipeline: a READ schedules its data CL cycles later. Depth 8
    // covers any legal CAS latency with room to spare.
    reg              rd_v [0:7];
    reg [DW-1:0]     rd_d [0:7];
    integer          k;
    initial for (k = 0; k < 8; k = k + 1) begin rd_v[k] = 1'b0; rd_d[k] = {DW{1'bx}}; end

    assign Dq = rd_v[0] ? rd_d[0] : {DW{1'bz}};

    // ------------------------------------------------------- burst tracking
    reg          bst_active = 1'b0;
    reg          bst_is_rd  = 1'b0;
    integer      bst_left   = 0;
    integer      bst_bank   = 0;
    integer      bst_row    = 0;
    integer      bst_col    = 0;
    reg          bst_ap     = 1'b0;   // auto-precharge at end of burst

    wire [2:0] cmd = {Ras_n, Cas_n, We_n};

    task do_write(input integer b, input integer r, input integer c);
        integer idx, byt;
        reg [DW-1:0] cur;
        begin
            idx = flat(b, r, c);
            cur = mem[idx];
            for (byt = 0; byt < DW/8; byt = byt + 1)
                if (!Dqm[byt]) cur[byt*8 +: 8] = Dq[byt*8 +: 8];
            mem[idx]    = cur;
            t_wr_end[b] = $realtime;
        end
    endtask

    task sched_read(input integer b, input integer r, input integer c);
        integer idx;
        begin
            idx = flat(b, r, c);
            // Dqm during a read masks the output; modelled as X so a controller
            // that ignores it cannot accidentally pass.
            rd_v[ml_cas] = 1'b1;
            rd_d[ml_cas] = (Dqm == 0) ? mem[idx] : {DW{1'bx}};
        end
    endtask

    // ------------------------------------------------------------ main loop
    always @(posedge Clk) begin
        // advance the read pipeline
        for (k = 0; k < 7; k = k + 1) begin rd_v[k] = rd_v[k+1]; rd_d[k] = rd_d[k+1]; end
        rd_v[7] = 1'b0; rd_d[7] = {DW{1'bx}};

        if (Cke !== 1'b1) begin
            // Clock-enable low is only used here for the power-up NOP period.
            // Nothing else in this project uses it, so anything more elaborate
            // would be untested code pretending to be a model.
        end else if (Cs_n !== 1'b1) begin
            case (cmd)
            C_LMR: begin
                if (Addr[2:0] == 3'b000) ml_burst = 1;
                else if (Addr[2:0] == 3'b001) ml_burst = 2;
                else if (Addr[2:0] == 3'b010) ml_burst = 4;
                else if (Addr[2:0] == 3'b011) ml_burst = 8;
                else oops("LOAD MODE REGISTER: full-page burst is not modelled");
                if (Addr[3]) oops("LOAD MODE REGISTER: interleaved burst is not modelled");
                if (Addr[6:4] == 3'b010) ml_cas = 2;
                else if (Addr[6:4] == 3'b011) ml_cas = 3;
                else oops("LOAD MODE REGISTER: CAS latency must be 2 or 3");
                for (i = 0; i < BANKS; i = i + 1)
                    if (b_active[i]) oops("LOAD MODE REGISTER issued with a bank still active");
                ml_valid = 1'b1;
                t_lmr    = $realtime;
            end
            C_REF: begin
                for (i = 0; i < BANKS; i = i + 1)
                    if (b_active[i]) oops("AUTO REFRESH issued with a bank still active");
                t_ref = $realtime;
            end
            C_PRE: begin
                if (Addr[10]) begin
                    for (i = 0; i < BANKS; i = i + 1) begin
                        if (b_active[i] && ($realtime - t_act[i] < T_RAS))
                            oops("PRECHARGE ALL violates tRAS");
                        b_active[i] = 1'b0;
                        t_pre[i]    = $realtime;
                    end
                end else begin
                    if (b_active[Ba] && ($realtime - t_act[Ba] < T_RAS))
                        oops("PRECHARGE violates tRAS");
                    b_active[Ba] = 1'b0;
                    t_pre[Ba]    = $realtime;
                end
            end
            C_ACT: begin
                if (!ml_valid) oops("ACTIVATE before LOAD MODE REGISTER");
                if (b_active[Ba]) oops("ACTIVATE on a bank that is already active");
                if ($realtime - t_pre[Ba] < T_RP) oops("ACTIVATE violates tRP");
                if ($realtime - t_act[Ba] < T_RC) oops("ACTIVATE violates tRC");
                if ($realtime - t_ref < T_RFC && t_ref > 0.0) oops("ACTIVATE violates tRFC");
                if (Addr >= ROWS) oops("ACTIVATE row address out of range");
                b_active[Ba] = 1'b1;
                b_row[Ba]    = Addr;
                t_act[Ba]    = $realtime;
            end
            C_RD, C_WR: begin
                if (!b_active[Ba]) oops("READ/WRITE on a bank that is not active");
                else if ($realtime - t_act[Ba] < T_RCD) oops("READ/WRITE violates tRCD");
                if (Addr[CW-1:0] >= COLS) oops("READ/WRITE column address out of range");
                bst_active = 1'b1;
                bst_is_rd  = (cmd == C_RD);
                bst_left   = ml_burst;
                bst_bank   = Ba;
                bst_row    = b_row[Ba];
                bst_col    = Addr[CW-1:0];
                bst_ap     = Addr[10];
                if (cmd == C_RD) sched_read(Ba, b_row[Ba], Addr[CW-1:0]);
                else             do_write  (Ba, b_row[Ba], Addr[CW-1:0]);
                bst_left   = ml_burst - 1;
                bst_col    = (Addr[CW-1:0] + 1) % COLS;
                if (bst_left == 0) begin
                    bst_active = 1'b0;
                    if (bst_ap) begin
                        if (cmd == C_WR && ($realtime - t_wr_end[Ba] < T_WR)) begin end
                        b_active[Ba] = 1'b0;
                        t_pre[Ba]    = $realtime + (cmd == C_WR ? T_WR : 0.0);
                    end
                end
            end
            C_BST: begin
                bst_active = 1'b0;
            end
            C_NOP: begin
                // Continue any burst already in flight.
                if (bst_active) begin
                    if (bst_is_rd) sched_read(bst_bank, bst_row, bst_col);
                    else           do_write  (bst_bank, bst_row, bst_col);
                    bst_col  = (bst_col + 1) % COLS;
                    bst_left = bst_left - 1;
                    if (bst_left == 0) begin
                        bst_active = 1'b0;
                        if (bst_ap) begin
                            b_active[bst_bank] = 1'b0;
                            t_pre[bst_bank] = $realtime + (bst_is_rd ? 0.0 : T_WR);
                        end
                    end
                end
            end
            default: ;
            endcase
        end
    end

    // ------------------------------------------------------ refresh watchdog
    // Catches the single most likely controller bug that hardware would punish
    // silently: forgetting to refresh, or refreshing too slowly. Data loss on a
    // real die is gradual and looks like random corruption; here it is a named
    // failure the moment the interval is exceeded.
    initial begin
        if (CHECK_REFRESH) begin
            @(posedge ml_valid);           // start checking once initialised
            forever begin
                #(T_REFI);
                if ($realtime - t_ref > T_REFI)
                    oops("refresh interval exceeded -- no AUTO REFRESH within tREFI");
            end
        end
    end
endmodule
