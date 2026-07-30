module bringup_selftest_top (
    input  wire       clk,      // pin 4, 27 MHz onboard oscillator
    input  wire       rst,      // pin 88, reset button (active-low idle-high; verify polarity on first bring-up)
    input  wire       uart_rx,  // pin 70, BL616 CDC-ACM bridge, host -> FPGA
    output wire       uart_tx,  // pin 69, BL616 CDC-ACM bridge, FPGA -> host
    output wire [5:0] leds      // pins 15-20, active-low
);
    localparam CLK_HZ = 27_000_000, BAUD = 1_000_000;
    localparam [7:0] SEED = 8'h01;
    localparam [7:0] CMD_RESYNC     = 8'hAA;
    localparam [7:0] CMD_FORCE_MOCK = 8'h4D; // 'M'
    localparam [7:0] CMD_FORCE_REAL = 8'h52; // 'R'

    wire rst_n = rst;

    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx), .data(rx_data), .valid(rx_valid)
    );

    // Mock/real mux convention (see CLAUDE.md): runtime-switchable, default MOCK.
    reg mode_mock = 1'b1;
    reg do_resync = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_mock <= 1'b1;
            do_resync <= 1'b0;
        end else begin
            do_resync <= 1'b0;
            if (rx_valid) case (rx_data)
                CMD_RESYNC:     do_resync <= 1'b1;
                CMD_FORCE_MOCK: mode_mock <= 1'b1;
                CMD_FORCE_REAL: mode_mock <= 1'b0;
                default: ;
            endcase
        end
    end

    wire [7:0] mock_data;
    lfsr8 #(.SEED(SEED)) u_lfsr (
        .clk(clk), .rst_n(rst_n),
        .en(tx_ready && mode_mock), .load_seed(do_resync),
        .value(mock_data)
    );

    // "Real" data source stub — placeholder for Phase 1's actual capture-FIFO output.
    reg [7:0] real_data_stub = 8'h00;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) real_data_stub <= 8'h00;
        else if (tx_ready && !mode_mock) real_data_stub <= real_data_stub + 8'h01;

    wire [7:0] tx_data = mode_mock ? mock_data : real_data_stub;

    wire tx_ready;
    reg  tx_valid;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tx_valid <= 1'b0;
        else tx_valid <= tx_ready; // keep the pipe full

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_data), .valid(tx_valid), .ready(tx_ready),
        .tx(uart_tx)
    );

    reg [23:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1'b1;

    reg [7:0] tx_count = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tx_count <= 0;
        else if (tx_valid) tx_count <= tx_count + 1'b1;

    assign leds[0]   = ~heartbeat[23]; // alive heartbeat
    assign leds[1]   = ~mode_mock;     // lit = MOCK mode active (default)
    assign leds[2]   = ~tx_count[7];   // toggles = data actively streaming
    assign leds[5:3] = 3'b111;         // off, reserved for future status bits
endmodule
