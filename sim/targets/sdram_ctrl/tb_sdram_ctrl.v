`timescale 1ns/1ps
//
// sdram_ctrl against the behavioural die model.
//
// The model is strict on purpose (see sim/models/sdram_sim.v): it checks the
// initialisation order, per-bank open/closed state, tRP/tRCD/tRAS/tRC/tRFC and
// the refresh interval, and reports any violation as a FAIL line. So this
// testbench gets two independent kinds of evidence -- data that survives a
// write/read round trip, and a protocol the model was willing to accept.
// Either alone would be weak: correct-looking data can come out of a controller
// that is violating timing and would fail on silicon, and a clean protocol says
// nothing about whether the right bytes landed in the right place.
//
module tb_sdram_ctrl;
    localparam integer CLK_HZ  = 108_000_000;
    localparam real    CLK_NS  = 1000.0 / 108.0;
    // The model allocates BANKS*ROWS*COLS words, so a full 2048-row part would
    // be 2M entries. Shrink the rows only; bank/column behaviour, and therefore
    // every address-decode path, is unchanged.
    localparam integer ROWS    = 16;

    reg clk = 1'b0, rst_n = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg         req = 1'b0, we = 1'b0;
    reg  [20:0] addr = 21'd0;
    reg  [31:0] wdata = 32'd0;
    reg  [3:0]  wmask = 4'd0;
    wire        ready, rvalid, init_done;
    wire [31:0] rdata;

    wire        s_clk, s_cke, s_cs_n, s_ras_n, s_cas_n, s_wen_n;
    wire [3:0]  s_dqm;
    wire [10:0] s_addr;
    wire [1:0]  s_ba;
    wire [31:0] s_dq;

    integer errors = 0;

    sdram_ctrl #(.CLK_HZ(CLK_HZ), .CAS_LAT(3)) dut (
        .clk(clk), .rst_n(rst_n),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .wmask(wmask),
        .ready(ready), .rdata(rdata), .rvalid(rvalid), .init_done(init_done),
        .O_sdram_clk(s_clk), .O_sdram_cke(s_cke), .O_sdram_cs_n(s_cs_n),
        .O_sdram_ras_n(s_ras_n), .O_sdram_cas_n(s_cas_n), .O_sdram_wen_n(s_wen_n),
        .O_sdram_dqm(s_dqm), .O_sdram_addr(s_addr), .O_sdram_ba(s_ba),
        .IO_sdram_dq(s_dq)
    );

    sdram_sim #(.ROWS(ROWS)) mem (
        .Clk(s_clk), .Cke(s_cke), .Cs_n(s_cs_n), .Ras_n(s_ras_n),
        .Cas_n(s_cas_n), .We_n(s_wen_n), .Ba(s_ba), .Addr(s_addr),
        .Dqm(s_dqm), .Dq(s_dq)
    );

    // Counted in clocks, not as a #delay: the ceiling in ps overflows Verilog's
    // default 32-bit unsized literal.
    integer wd = 0;
    always @(posedge clk) begin
        wd = wd + 1;
        if (wd > 3_000_000) begin
            $display("FAIL: watchdog expired at %0t (state=%0d)", $realtime, dut.state);
            $fatal(1);
        end
    end

    function [20:0] mk_addr(input integer bank, input integer row, input integer col);
        mk_addr = {bank[1:0], row[10:0], col[7:0]};
    endfunction

    task do_write(input [20:0] a, input [31:0] d, input [3:0] m);
        begin
            @(posedge clk);
            while (!ready) @(posedge clk);
            req <= 1'b1; we <= 1'b1; addr <= a; wdata <= d; wmask <= m;
            @(posedge clk);
            req <= 1'b0;
        end
    endtask

    task do_read(input [20:0] a, output [31:0] d);
        begin
            @(posedge clk);
            while (!ready) @(posedge clk);
            req <= 1'b1; we <= 1'b0; addr <= a;
            @(posedge clk);
            req <= 1'b0;
            while (!rvalid) @(posedge clk);
            d = rdata;
        end
    endtask

    task check_at(input [20:0] a, input [31:0] want, input [1023:0] what);
        reg [31:0] got;
        begin
            do_read(a, got);
            if (got !== want) begin
                $display("FAIL: %0s at addr 0x%06x: got 0x%08x expected 0x%08x",
                         what, a, got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer i, b, r;
    reg [31:0] got;
    real t0, t_init;

    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        t0 = $realtime;

        // ---- 1. initialisation completes, and takes at least the 200 us the
        //         device requires before any command may be issued.
        while (!init_done) @(posedge clk);
        t_init = $realtime - t0;
        $display("INFO: init_done after %0.1f us", t_init/1000.0);
        if (t_init < 200000.0) begin
            $display("FAIL: initialisation took %0.1f us, must be at least 200 us", t_init/1000.0);
            errors = errors + 1;
        end

        // ---- 2. write then read back, same row
        do_write(mk_addr(0, 0, 0), 32'hDEAD_BEEF, 4'h0);
        do_write(mk_addr(0, 0, 1), 32'h0123_4567, 4'h0);
        check_at(mk_addr(0, 0, 0), 32'hDEAD_BEEF, "same-row readback");
        check_at(mk_addr(0, 0, 1), 32'h0123_4567, "same-row readback");

        // ---- 3. every bank, and rows either side of a row change.
        // Columns start at 16 so the sweep cannot land on column 0, which
        // step 2 already owns. The first version used col = b*4+r, which for
        // bank 0 row 0 is column 0 -- it silently overwrote the earlier value
        // and only surfaced 200 us later as a stale-data failure that looked
        // like a refresh bug.
        for (b = 0; b < 4; b = b + 1)
            for (r = 0; r < 4; r = r + 1)
                do_write(mk_addr(b, r, 16 + b*4 + r), 32'hA5A5_0000 | (b << 8) | r, 4'h0);
        for (b = 0; b < 4; b = b + 1)
            for (r = 0; r < 4; r = r + 1)
                check_at(mk_addr(b, r, 16 + b*4 + r), 32'hA5A5_0000 | (b << 8) | r,
                       "bank/row sweep");
        $display("INFO: 16 bank/row combinations written and read back");

        // ---- 4. byte masking must leave masked bytes untouched
        do_write(mk_addr(1, 2, 100), 32'h1122_3344, 4'h0);
        do_write(mk_addr(1, 2, 100), 32'hFFFF_FFFF, 4'b0110);  // only bytes 0 and 3
        check_at(mk_addr(1, 2, 100), 32'hFF22_33FF, "byte mask");

        // ---- 5. a column walk across a row boundary
        for (i = 0; i < 8; i = i + 1)
            do_write(mk_addr(2, 5, 250 + i), 32'h5A5A_0000 | i, 4'h0);
        for (i = 0; i < 8; i = i + 1)
            check_at(mk_addr(2, 5, 250 + i), 32'h5A5A_0000 | i, "column walk");

        // ---- 6. run idle long enough for the model's refresh watchdog to have
        //         something to say if refresh were missing. It checks every
        //         tREFI (15.625 us); 200 us is a dozen opportunities.
        repeat (22000) @(posedge clk);
        check_at(mk_addr(0, 0, 0), 32'hDEAD_BEEF, "data after a long idle period");

        // ---- verdict: our checks AND the model's
        if (mem.errors != 0) begin
            $display("FAIL: the SDRAM model reported %0d protocol violation(s)", mem.errors);
            errors = errors + mem.errors;
        end
        if (errors == 0) begin
            $display("PASS: sdram_ctrl, init + read/write + all 4 banks + byte mask + refresh, 0 errors");
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1);
        end
    end
endmodule
