`timescale 1ns/1ps
module tb_uart_loopback;
    localparam CLK_HZ = 27_000_000, BAUD = 1_000_000;
    localparam CLK_PS = 1_000_000_000 / CLK_HZ;

    reg clk = 0, rst_n = 0;
    always #(CLK_PS/2) clk = ~clk;

    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_ready;
    wire       line;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut_tx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_data), .valid(tx_valid), .ready(tx_ready),
        .tx(line)
    );

    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut_rx (
        .clk(clk), .rst_n(rst_n),
        .rx(line),
        .data(rx_data), .valid(rx_valid)
    );

    integer errors = 0, sent = 0, received = 0, i;
    reg [7:0] expected_q [0:63];

    task send_byte(input [7:0] b);
        begin
            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_data <= b;
            tx_valid <= 1'b1;
            expected_q[sent] = b;
            sent = sent + 1;
            @(posedge clk);
            tx_valid <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (rx_valid) begin
            if (rx_data !== expected_q[received]) begin
                $display("FAIL: byte %0d mismatch: expected=0x%02x got=0x%02x",
                          received, expected_q[received], rx_data);
                errors <= errors + 1;
            end
            received <= received + 1;
        end
    end

    initial begin
        tx_valid = 0;
        tx_data  = 0;
        rst_n    = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        send_byte(8'h00);
        send_byte(8'hFF);
        for (i = 0; i < 32; i = i + 1) send_byte(i[7:0] ^ 8'hA5);

        #500000; // generous margin; ~34 bytes @1Mbaud/27MHz completes well under this

        if (received != sent) begin
            $display("FAIL: sent %0d bytes but received %0d", sent, received);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: uart_tx/uart_rx loopback, %0d bytes verified, 0 errors", received);
            $finish;
        end else begin
            $display("FAIL: %0d error(s) out of %0d bytes", errors, sent);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: testbench timeout");
        $fatal(1);
    end
endmodule
