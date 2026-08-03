`timescale 1ns/1ps
//
// Top-level testbench for frame_capture: synthetic video in on the probe pins,
// through synchronous sampling, packing, SDRAM and the read-back path, decoded
// back into video timing at the far end.
//
// The stimulus is video_timing_gen -- Phase 1's mock source, reused here as the
// testbench's signal generator rather than as part of the design. That is worth
// doing deliberately: it is an independent implementation of the protocol from
// anything in this data path, so agreement between the two is evidence rather
// than tautology, and it already has its own passing tests from Phase 1.
//
// The SDRAM model is strict, so reaching PASS also demonstrates that a capture
// running at full sample rate never violated tRCD/tRC or missed a refresh --
// exactly the conditions a real die punishes with silent corruption.
//
module tb_frame_capture;
    localparam real    CLK_NS = 1000.0 / 27.0;
    localparam real    BIT_NS = 1000.0;
    localparam integer ROWS   = 16;

    // A deliberately tiny frame so a capture and its read-back fit in a
    // reasonable simulation. Structure is what matters, not size.
    localparam integer DOTCLK_DIV = 8;    // 108/8 = 13.5 MHz, close to the real 13.29
    localparam integer H_TOTAL = 20, H_SYNC = 2, H_START = 4, H_ACTIVE = 12;
    localparam integer V_TOTAL = 6,  V_SYNC = 1, V_START = 2, V_ACTIVE = 3;
    localparam integer FRAME_DOTCLKS = H_TOTAL * V_TOTAL;      // 120
    localparam integer CAP_WORDS     = FRAME_DOTCLKS / 2;      // 60

    localparam [7:0] CMD_RESET = 8'hAA, CMD_ARM = 8'h41,
                     CMD_STATUS = 8'h53, CMD_READ = 8'h47;

    reg  clk = 1'b0, rx = 1'b1;
    wire tx;
    wire [5:0] leds;
    integer errors = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    // ---- stimulus: an independent video generator on its own 108 MHz clock
    reg gclk = 1'b0;
    always #(1000.0/108.0/2.0) gclk = ~gclk;
    reg grst_n = 1'b0;

    wire g_dotclk, g_hsync, g_vsync, g_de;
    wire [7:0] g_data;
    video_timing_gen #(
        .DOTCLK_DIV(DOTCLK_DIV), .H_TOTAL(H_TOTAL), .H_SYNC(H_SYNC),
        .H_START(H_START), .H_ACTIVE(H_ACTIVE), .V_TOTAL(V_TOTAL),
        .V_SYNC(V_SYNC), .V_START(V_START), .V_ACTIVE(V_ACTIVE)
    ) u_src (
        .clk(gclk), .rst_n(grst_n), .restart(1'b0),
        .dotclk(g_dotclk), .hsync(g_hsync), .vsync(g_vsync),
        .de(g_de), .data(g_data)
    );

    wire [11:0] probe = {g_data, g_de, g_vsync, g_hsync, g_dotclk};

    wire s_clk, s_cke, s_cs_n, s_ras_n, s_cas_n, s_wen_n;
    wire [3:0] s_dqm; wire [10:0] s_addr; wire [1:0] s_ba; wire [31:0] s_dq;

    frame_capture_top #(.CAP_WORDS(CAP_WORDS)) dut (
        .clk(clk), .uart_rx(rx), .uart_tx(tx), .probe(probe), .leds(leds),
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

    integer wd = 0;
    always @(posedge clk) begin
        wd = wd + 1;
        if (wd > 4_000_000) begin
            $display("FAIL: watchdog expired at %0t (cap=%0d words=%0d)",
                     $realtime, dut.cap, dut.words_cap);
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
            @(negedge tx); #(BIT_NS * 1.5);
            for (i = 0; i < 8; i = i + 1) begin b[i] = tx; #(BIT_NS); end
        end
    endtask

    reg [7:0]  rep [0:11];
    reg [7:0]  r_status;
    reg [31:0] r_words;
    reg [15:0] r_runts, r_reply;
    reg [31:0] words [0:CAP_WORDS-1];

    task read_report;
        integer i;
        begin
            for (i = 0; i < 12; i = i + 1) recv_byte(rep[i]);
            r_status = rep[2];
            r_words  = {rep[7], rep[6], rep[5], rep[4]};
            r_runts  = {rep[9], rep[8]};
            r_reply  = {rep[11], rep[10]};
            if (rep[0] !== 8'hA5 || rep[1] !== 8'h04) begin
                $display("FAIL: report magic/version 0x%02x/0x%02x", rep[0], rep[1]);
                errors = errors + 1;
            end
        end
    endtask

    // The reply starts during the stop bit of the command, so the receiver must
    // be armed first -- same race as every other target in this repo.
    task cmd_report(input [7:0] c);
        begin fork send_byte(c); read_report; join end
    endtask

    task read_words(input [31:0] start, input [15:0] count);
        integer i, j;
        reg [7:0] b0, b1, b2, b3;
        begin
            fork
                begin
                    send_byte(CMD_READ);
                    send_byte(start[7:0]);   send_byte(start[15:8]);
                    send_byte(start[23:16]); send_byte(start[31:24]);
                    send_byte(count[7:0]);   send_byte(count[15:8]);
                end
                begin
                    read_report;
                    for (i = 0; i < r_reply; i = i + 1) begin
                        recv_byte(b0); recv_byte(b1); recv_byte(b2); recv_byte(b3);
                        words[start + i] = {b3, b2, b1, b0};
                    end
                end
            join
        end
    endtask

    // ---- decode the packed capture back into per-DOTCLK samples
    reg [10:0] smp [0:2*CAP_WORDS-1];
    integer i, j, polls, run, first, nsmp, hfalls, prev_h;
    integer y_seen, x_seen, comp;
    reg [7:0] want;

    initial begin
        #400_000.0;
        grst_n <= 1'b1;
        // SDRAM initialisation is 200 us of NOP before anything else.
        #400_000.0;

        cmd_report(CMD_STATUS);
        if (!r_status[0] || !r_status[1]) begin
            $display("FAIL: pll_lock=%b sdram_init=%b", r_status[0], r_status[1]);
            errors = errors + 1;
        end
        $display("INFO: PLL locked, SDRAM initialised");

        send_byte(CMD_ARM);
        polls = 0; r_status = 8'h00;
        while (!r_status[4] && polls < 40) begin
            cmd_report(CMD_STATUS);
            polls = polls + 1;
        end
        if (!r_status[4]) begin
            $display("FAIL: capture never completed (status=0x%02x words=%0d)",
                     r_status, r_words);
            errors = errors + 1;
        end
        $display("INFO: captured %0d words, %0d runt edges rejected", r_words, r_runts);
        if (r_words !== CAP_WORDS) begin
            $display("FAIL: captured %0d words, expected %0d", r_words, CAP_WORDS);
            errors = errors + 1;
        end
        if (r_status[5]) begin
            $display("FAIL: overrun -- a sample was lost between the sampler and SDRAM");
            errors = errors + 1;
        end

        read_words(32'd0, CAP_WORDS[15:0]);
        if (r_reply !== CAP_WORDS) begin
            $display("FAIL: read-back returned %0d words, asked for %0d", r_reply, CAP_WORDS);
            errors = errors + 1;
        end

        nsmp = 0;
        for (i = 0; i < CAP_WORDS; i = i + 1) begin
            smp[nsmp]   = words[i][10:0];
            smp[nsmp+1] = words[i][26:16];
            nsmp = nsmp + 2;
        end

        // A capture armed on a VSYNC falling edge covers exactly one frame, so
        // the recovered line structure must match the generator's parameters.
        hfalls = 0; prev_h = -1;
        for (i = 1; i < nsmp; i = i + 1)
            if (!smp[i][0] && smp[i-1][0]) begin
                if (prev_h >= 0 && (i - prev_h) !== H_TOTAL) begin
                    $display("FAIL: HSYNC period %0d DOTCLKs, expected %0d", i - prev_h, H_TOTAL);
                    errors = errors + 1;
                end
                prev_h = i; hfalls = hfalls + 1;
            end
        if (hfalls < 2) begin
            $display("FAIL: only %0d HSYNC falling edges in %0d samples", hfalls, nsmp);
            errors = errors + 1;
        end

        // DE runs, and the R/G/B test pattern inside them. A run starting at
        // sample 0 was already in progress when the capture began and is
        // truncated by construction, so it is skipped.
        run = 0; first = -1;
        for (i = 0; i < nsmp; i = i + 1) begin
            if (smp[i][2]) begin
                if (run == 0) first = i;
                run = run + 1;
            end else if (run != 0) begin
                if (first > 0 && run !== H_ACTIVE) begin
                    $display("FAIL: DE run of %0d DOTCLKs at %0d, expected %0d",
                             run, first, H_ACTIVE);
                    errors = errors + 1;
                end else if (first > 0) begin
                    y_seen = smp[first+1][10:3];
                    for (j = 0; j < H_ACTIVE; j = j + 1) begin
                        x_seen = j / 3; comp = j % 3;
                        case (comp)
                            0: want = x_seen[7:0];
                            1: want = y_seen[7:0];
                            default: want = x_seen[7:0] ^ y_seen[7:0];
                        endcase
                        if (smp[first+j][10:3] !== want) begin
                            $display("FAIL: pixel at DOTCLK %0d (x=%0d comp=%0d y=%0d): got 0x%02x expected 0x%02x",
                                     first+j, x_seen, comp, y_seen, smp[first+j][10:3], want);
                            errors = errors + 1;
                            j = H_ACTIVE;
                        end
                    end
                end
                run = 0;
            end
        end
        if (first < 0) begin
            $display("FAIL: DE never asserted in the capture");
            errors = errors + 1;
        end
        $display("INFO: %0d samples decoded: HSYNC period %0d, DE runs of %0d, pattern verified",
                 nsmp, H_TOTAL, H_ACTIVE);

        if (mem.errors != 0) begin
            $display("FAIL: the SDRAM model reported %0d protocol violation(s)", mem.errors);
            errors = errors + mem.errors;
        end
        if (errors == 0) begin
            $display("PASS: frame_capture, VSYNC-aligned capture through SDRAM + read-back, decoded and verified, 0 errors");
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1);
        end
    end
endmodule
