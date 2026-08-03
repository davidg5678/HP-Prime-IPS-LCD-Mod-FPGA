`timescale 1ns/1ps
//
// Top-level testbench for frame_stream: synthetic video in on the probe pins,
// out as a live RLE byte stream, decoded back into pixels and compared against
// what the generator was asked to produce.
//
// The stimulus is Phase 1's video_timing_gen -- an implementation of the
// protocol independent of everything in this data path, so agreement is
// evidence rather than tautology.
//
// Streaming is continuous once started, so this also checks the property that
// makes the stream usable at all: it is SELF-FRAMING. An RLE count is never
// zero, so 0x00 can escape a frame marker with no risk of colliding with run
// data, and a host can join mid-stream and resynchronise.
//
module tb_frame_stream;
    localparam real    CLK_NS = 1000.0 / 27.0;
    localparam real    BIT_NS = 1000.0;
    localparam integer ROWS   = 16;

    localparam integer DOTCLK_DIV = 8;
    localparam integer H_TOTAL = 20, H_SYNC = 2, H_START = 4, H_ACTIVE = 12;
    localparam integer V_TOTAL = 6,  V_SYNC = 1, V_START = 2, V_ACTIVE = 3;
    localparam integer XPIX = H_ACTIVE / 3;               // 4 pixels per line
    localparam integer NPIX = XPIX * V_ACTIVE;            // 12 per frame

    localparam [7:0] CMD_STOP = 8'hAA, CMD_RUN = 8'h52, CMD_STATUS = 8'h53;

    reg  clk = 1'b0, rx = 1'b1;
    wire tx;
    wire [5:0] leds;
    integer errors = 0;
    always #(CLK_NS/2.0) clk = ~clk;

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

    frame_stream_top dut (
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
            $display("FAIL: watchdog expired at %0t (st=%0d)", $realtime, dut.st);
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

    reg [7:0] b, b0, b1, b2, b3;
    reg [7:0] rep [0:7];
    integer i, j, np, guard;
    reg [7:0] px_r [0:255];
    reg [7:0] px_g [0:255];
    reg [7:0] px_b [0:255];
    integer x, y;
    reg [7:0] wr, wg, wb;

    initial begin
        #400_000.0;
        grst_n <= 1'b1;
        #400_000.0;

        // ---- status while idle
        fork
            send_byte(CMD_STATUS);
            for (i = 0; i < 8; i = i + 1) recv_byte(rep[i]);
        join
        if (rep[0] !== 8'hA5 || rep[1] !== 8'h05) begin
            $display("FAIL: report magic/version 0x%02x/0x%02x", rep[0], rep[1]);
            errors = errors + 1;
        end
        if (!rep[2][0] || !rep[2][1]) begin
            $display("FAIL: pll_lock=%b sdram_init=%b", rep[2][0], rep[2][1]);
            errors = errors + 1;
        end
        $display("INFO: PLL locked, SDRAM initialised");

        // ---- start streaming, then resynchronise on a frame marker
        send_byte(CMD_RUN);

        guard = 0; b0 = 8'hFF; b1 = 8'hFF;
        while (!(b0 == 8'h00 && b1 == 8'h01) && guard < 400) begin
            b0 = b1;
            recv_byte(b1);
            guard = guard + 1;
        end
        if (guard >= 400) begin
            $display("FAIL: no frame marker (00 01) found in the stream");
            errors = errors + 1;
        end else begin
            $display("INFO: frame marker found after %0d bytes", guard);
        end

        // ---- decode runs until a whole frame's worth of pixels is rebuilt
        np = 0; guard = 0;
        while (np < NPIX && guard < 400) begin
            recv_byte(b0);           // count
            if (b0 == 8'h00) begin
                recv_byte(b1);       // marker; a new frame started early
                $display("FAIL: unexpected marker 00 %02x after only %0d of %0d pixels",
                         b1, np, NPIX);
                errors = errors + 1;
                guard = 400;
            end else begin
                recv_byte(b1); recv_byte(b2); recv_byte(b3);
                for (j = 0; j < b0; j = j + 1) begin
                    if (np < 256) begin
                        px_r[np] = b1; px_g[np] = b2; px_b[np] = b3;
                    end
                    np = np + 1;
                end
            end
            guard = guard + 1;
        end
        $display("INFO: rebuilt %0d pixels from the stream (expected %0d)", np, NPIX);
        if (np !== NPIX) begin
            $display("FAIL: rebuilt %0d pixels, expected %0d", np, NPIX);
            errors = errors + 1;
        end

        // ---- compare against what the generator was asked to produce:
        //      R = x, G = y, B = x ^ y, filling left to right, top to bottom
        for (i = 0; i < NPIX && i < np; i = i + 1) begin
            x = i % XPIX;
            y = i / XPIX;
            wr = x[7:0]; wg = y[7:0]; wb = x[7:0] ^ y[7:0];
            if (px_r[i] !== wr || px_g[i] !== wg || px_b[i] !== wb) begin
                $display("FAIL: pixel %0d (x=%0d y=%0d): got %02x %02x %02x expected %02x %02x %02x",
                         i, x, y, px_r[i], px_g[i], px_b[i], wr, wg, wb);
                errors = errors + 1;
                i = NPIX;
            end
        end

        send_byte(CMD_STOP);

        if (mem.errors != 0) begin
            $display("FAIL: the SDRAM model reported %0d protocol violation(s)", mem.errors);
            errors = errors + mem.errors;
        end
        if (errors == 0) begin
            $display("PASS: frame_stream, live RLE stream through SDRAM, %0d pixels rebuilt and verified, 0 errors", NPIX);
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1);
        end
    end
endmodule
