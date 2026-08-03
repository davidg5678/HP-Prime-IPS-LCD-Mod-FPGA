`timescale 1ns/1ps
//
// Top-level testbench for sdram_selftest: the whole path from a UART command
// byte, through the PLL and the controller, into the behavioural die model and
// back out as a status report.
//
// The SDRAM model is strict (see sim/models/sdram_sim.v), so a run that reaches
// PASS has also demonstrated that nothing in the integrated design violated the
// initialisation order, tRP/tRCD/tRAS/tRC or the refresh interval -- constraints
// the real die enforces by corrupting data rather than by complaining.
//
module tb_sdram_selftest;
    localparam real    CLK_NS = 1000.0 / 27.0;   // 27 MHz reference
    localparam real    BIT_NS = 1000.0;          // 1 Mbaud
    localparam integer WORDS  = 200;             // enough to cross a column run
    localparam integer ROWS   = 16;              // shrink the model's storage

    localparam [7:0] CMD_RESET = 8'hAA, CMD_TEST = 8'h54, CMD_STATUS = 8'h53;

    reg  clk = 1'b0, rx = 1'b1;
    wire tx;
    wire [5:0] leds;
    wire s_clk, s_cke, s_cs_n, s_ras_n, s_cas_n, s_wen_n;
    wire [3:0] s_dqm; wire [10:0] s_addr; wire [1:0] s_ba; wire [31:0] s_dq;
    integer errors = 0;

    always #(CLK_NS/2.0) clk = ~clk;

    sdram_selftest_top #(.TEST_WORDS(WORDS)) dut (
        .clk(clk), .uart_rx(rx), .uart_tx(tx), .leds(leds),
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
        if (wd > 4_000_000) begin
            $display("FAIL: watchdog expired at %0t (bist=%0d)", $realtime, dut.bist);
            $fatal(1);
        end
    end

    task send_byte(input [7:0] b);
        integer i;
        begin
            rx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin rx = b[i]; #(BIT_NS); end
            rx = 1'b1; #(BIT_NS);
        end
    endtask

    task recv_byte(output [7:0] b);
        integer i;
        begin
            @(negedge tx);
            #(BIT_NS * 1.5);
            for (i = 0; i < 8; i = i + 1) begin b[i] = tx; #(BIT_NS); end
        end
    endtask

    reg [7:0]  rep [0:10];
    reg [7:0]  r_status;
    reg [31:0] r_ok, r_err;

    task read_report;
        integer i;
        begin
            for (i = 0; i < 11; i = i + 1) recv_byte(rep[i]);
            r_status = rep[2];
            r_ok  = {rep[6], rep[5], rep[4], rep[3]};
            r_err = {rep[10], rep[9], rep[8], rep[7]};
            if (rep[0] !== 8'hA5 || rep[1] !== 8'h03) begin
                $display("FAIL: report magic/version 0x%02x/0x%02x", rep[0], rep[1]);
                errors = errors + 1;
            end
        end
    endtask

    // The reply begins during the stop bit of the command, so the receiver must
    // already be armed -- the same race documented in the la_capture testbench.
    task cmd_report(input [7:0] c);
        begin
            fork
                send_byte(c);
                read_report;
            join
        end
    endtask

    integer polls;

    initial begin
        // PLL lock plus a 2^15-cycle power-on reset at 108 MHz, then the
        // controller's own mandatory 200 us SDRAM power-up wait.
        #700_000.0;

        cmd_report(CMD_STATUS);
        if (!r_status[0]) begin
            $display("FAIL: SDRAM controller never reported init_done (status=0x%02x)", r_status);
            errors = errors + 1;
        end
        if (!r_status[4]) begin
            $display("FAIL: PLL not locked (status=0x%02x)", r_status);
            errors = errors + 1;
        end
        $display("INFO: init_done, PLL locked");

        send_byte(CMD_TEST);
        polls = 0;
        r_status = 8'h00;
        while (!r_status[2] && polls < 60) begin
            cmd_report(CMD_STATUS);
            polls = polls + 1;
        end
        if (!r_status[2]) begin
            $display("FAIL: BIST never completed after %0d polls (status=0x%02x, ok=%0d)",
                     polls, r_status, r_ok);
            errors = errors + 1;
        end else begin
            $display("INFO: BIST done: %0d words verified, %0d mismatches", r_ok, r_err);
            if (r_ok !== WORDS) begin
                $display("FAIL: verified %0d words, expected %0d", r_ok, WORDS);
                errors = errors + 1;
            end
            if (r_err !== 0) begin
                $display("FAIL: %0d mismatches reading back the pattern", r_err);
                errors = errors + 1;
            end
            if (r_status[3]) begin
                $display("FAIL: status reports the test failed");
                errors = errors + 1;
            end
        end

        if (mem.errors != 0) begin
            $display("FAIL: the SDRAM model reported %0d protocol violation(s)", mem.errors);
            errors = errors + mem.errors;
        end
        if (errors == 0) begin
            $display("PASS: sdram_selftest top-level, PLL + init + %0d-word BIST over UART, 0 errors", WORDS);
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1);
        end
    end
endmodule
