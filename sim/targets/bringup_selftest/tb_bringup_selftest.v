`timescale 1ps/1ps
//
// Top-level testbench for bringup_selftest_top. This is the test that was
// missing: bringup_uart_loopback only exercises uart_tx/uart_rx against each
// other, so nothing ever checked the *integration* -- the baud actually
// produced on the pin, the LFSR-to-byte cadence, or the command channel.
//
// Checks, in order:
//   1. uart_tx's on-the-wire bit time matches the design's BAUD localparam.
//   2. The LFSR advances exactly once per transmitted byte (a 2x advance makes
//      the FPGA stream disagree with serial_selftest.py's reference model).
//   3. The decoded byte stream matches that same reference model.
//   4. The RX command channel works: 0xAA reaches the design (rx_ever latches).
//
module tb_bringup_selftest;
    localparam integer CLK_HZ  = 27_000_000;
    localparam integer BAUD    = 38_400;    // must match bringup_selftest_top.v
    localparam integer HALF_PS = 500_000_000_000 / CLK_HZ; // 18518 ps
    localparam integer BIT_PS  = 1_000_000_000_000 / BAUD; // 8680555 ps
    localparam [7:0]   SEED    = 8'h01;
    localparam [7:0]   CMD_RESYNC = 8'hAA;
    localparam integer NBYTES  = 64;

    reg clk = 0;
    always #(HALF_PS) clk = ~clk;

    reg        rx_line = 1'b1;
    wire       tx_line;
    wire [5:0] leds;

    bringup_selftest_top dut (
        .clk(clk), .rst(1'b1),
        .uart_rx(rx_line), .uart_tx(tx_line),
        .leds(leds)
    );

    integer errors = 0;

    // ---- reference model: mirrors lfsr_next() in python/tools/serial_selftest.py
    function [7:0] lfsr_next(input [7:0] v);
        reg fb;
        begin
            fb = v[7] ^ v[5] ^ v[4] ^ v[3];
            lfsr_next = {v[6:0], fb};
        end
    endfunction

    // ---- check 2 instrumentation: byte launches vs LFSR advances
    integer byte_launches = 0, lfsr_advances = 0;
    reg counting = 0;
    always @(posedge clk) if (counting) begin
        if (dut.tx_ready && dut.tx_valid) byte_launches <= byte_launches + 1;
        if (dut.u_lfsr.en && !dut.u_lfsr.load_seed) lfsr_advances <= lfsr_advances + 1;
    end

    // ---- behavioural UART receiver at the *expected* baud
    task rx_byte(output [7:0] b);
        integer i;
        begin
            @(negedge tx_line);
            #(BIT_PS + BIT_PS / 2); // centre of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = tx_line;
                #(BIT_PS);
            end
        end
    endtask

    task send_byte(input [7:0] b);
        integer i;
        begin
            rx_line = 1'b0; #(BIT_PS);              // start
            for (i = 0; i < 8; i = i + 1) begin
                rx_line = b[i]; #(BIT_PS);
            end
            rx_line = 1'b1; #(BIT_PS);              // stop
        end
    endtask

    // ---- check 1: measure the narrowest edge-to-edge interval on the wire.
    // In UART framing the shortest possible pulse is exactly one bit time.
    real t_prev, t_now, delta, min_delta;
    reg  measuring = 0;
    initial begin
        min_delta = 1.0e18;
        t_prev    = 0.0;
        forever begin
            @(tx_line);
            if (measuring) begin
                t_now = $realtime;
                if (t_prev > 0.0) begin
                    delta = t_now - t_prev;
                    if (delta < min_delta) min_delta = delta;
                end
                t_prev = t_now;
            end
        end
    end

    integer i;
    reg [7:0] got, expect_b;
    real measured_baud;
    integer first_seed_at;
    reg [7:0] cap [0:NBYTES-1];

    initial begin
        // Power-on reset inside the DUT releases after ~32768 clocks.
        repeat (40000) @(posedge clk);

        // ---- check 0: the design is burst-on-demand, so the line must be
        // idle high until a command arrives. A busy line here means it has
        // reverted to free-running, which destroys receiver framing.
        if (tx_line !== 1'b1) begin
            $display("FAIL: uart_tx is not idle before any command was sent");
            errors = errors + 1;
        end

        // ---- check 4: RX command channel
        if (leds[3] !== 1'b1) begin
            $display("FAIL: rx_ever was already set before any byte was sent");
            errors = errors + 1;
        end
        // ---- checks 1 + 2 run concurrently with the capture below
        measuring = 1;
        counting  = 1;

        // The receiver MUST be armed before the command finishes going out.
        // uart_rx asserts rx_valid at the middle of the stop bit (~9.5 bit
        // times), and the burst's first start bit follows ~4 clocks later --
        // i.e. while send_byte is still blocked driving its own stop bit out
        // to t=10. Running these sequentially arms the capture ~0.5 bit times
        // too late and misframes every byte. A real host doesn't have this
        // problem: its UART is always listening and the OS buffers the bytes.
        //
        // ---- check 3: the burst is deterministic, so byte 0 must be SEED
        // exactly -- no searching for a sync point.
        fork
            begin : capture
                for (i = 0; i < NBYTES; i = i + 1) rx_byte(cap[i]);
            end
            begin : command
                send_byte(CMD_RESYNC);
            end
        join

        measuring = 0;
        counting  = 0;

        if (leds[3] !== 1'b0) begin
            $display("FAIL: RX command channel dead -- 0xAA did not set rx_ever (leds[3])");
            errors = errors + 1;
        end

        measured_baud = 1.0e12 / min_delta;
        $display("INFO: narrowest edge-to-edge = %.0f ps -> baud ~= %.0f (expected %0d)",
                 min_delta, measured_baud, BAUD);
        if (measured_baud < BAUD * 0.98 || measured_baud > BAUD * 1.02) begin
            $display("FAIL: uart_tx bit time is wrong on the wire: measured baud %.0f, expected %0d",
                     measured_baud, BAUD);
            errors = errors + 1;
        end

        $display("INFO: %0d byte launches, %0d LFSR advances", byte_launches, lfsr_advances);
        if (byte_launches == 0) begin
            $display("FAIL: design transmitted nothing at all");
            errors = errors + 1;
        end else if (lfsr_advances != byte_launches) begin
            $display("FAIL: LFSR advanced %0d times for %0d transmitted bytes (must be 1:1)",
                     lfsr_advances, byte_launches);
            errors = errors + 1;
        end

        expect_b = SEED;
        for (i = 0; i < NBYTES; i = i + 1) begin
            if (cap[i] !== expect_b) begin
                $display("FAIL: byte %0d mismatch: expected=0x%02x got=0x%02x (first 8 captured: %02x %02x %02x %02x %02x %02x %02x %02x)",
                         i, expect_b, cap[i],
                         cap[0], cap[1], cap[2], cap[3], cap[4], cap[5], cap[6], cap[7]);
                errors = errors + 1;
                i = NBYTES;
            end else begin
                expect_b = lfsr_next(expect_b);
            end
        end

        if (errors == 0)
            $display("PASS: bringup_selftest top-level, baud + LFSR cadence + command channel verified");
        else
            $fatal(1, "FAIL: %0d error(s)", errors);
        $finish;
    end

    // watchdog -- counted in clocks, not a #delay: the ~22ms ceiling this needs
    // does not fit in Verilog's default 32-bit unsized literal when expressed in ps.
    initial begin
        repeat (1_500_000) @(posedge clk); // ~55 ms at 27 MHz
        $display("FAIL: watchdog timeout");
        $fatal(1);
    end
endmodule
