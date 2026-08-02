module bringup_selftest_top (
    input  wire       clk,      // pin 4, 27 MHz onboard oscillator
    input  wire       rst,      // pin 88, MODE0 config strap -- NOT in the reset path, diagnostic only (leds[4]); see below
    input  wire       uart_rx,  // pin 70, onboard BL616 UART, host -> FPGA
    output wire       uart_tx,  // pin 69, onboard BL616 UART, FPGA -> host
    output wire [5:0] leds      // pins 15-20, active-low
);
    // BAUD must match BAUD in python/tools/serial_selftest.py and the tb.
    // 1_000_000 divides the 27 MHz clock exactly (DIV = 27, zero error). The
    // earlier 38400 was a limit of the temporary Arduino bridge's bit-banged
    // SoftwareSerial, not of this design or the BL616 -- see PROGRESS.md.
    localparam CLK_HZ = 27_000_000, BAUD = 1_000_000;
    localparam [7:0] SEED = 8'h01;
    localparam [7:0] CMD_RESYNC     = 8'hAA;
    localparam [7:0] CMD_FORCE_MOCK = 8'h4D; // 'M'
    localparam [7:0] CMD_FORCE_REAL = 8'h52; // 'R'

    // Power-on reset, deliberately NOT derived from the `rst` input pin.
    //
    // Confirmed: pin 88 carries this device's MODE0 configuration-strap
    // function -- see the Function column for `rst` in impl/pnr/project.rpt.txt.
    // Inferred: it therefore sits low regardless of PULL_MODE=UP, which held
    // `rst_n` asserted and the entire design in reset. Driving reset from an
    // internal POR instead took the design from transmitting nothing at all to
    // a passing end-to-end self-test, which is what actually settles it.
    // leds[4] exposes the raw pin level to confirm visually.
    //
    // What made this take so long to find: the heartbeat counter below is the
    // ONE register in this module with no reset term, so leds[0] kept blinking
    // the whole time and every "the bitstream is alive" check passed while the
    // design was in fact held in reset. See PROGRESS.md 2026-08-02.
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;
    always @(posedge clk) begin
        if (!por_cnt[15]) por_cnt <= por_cnt + 1'b1;
        rst_n <= por_cnt[15]; // releases ~1.2ms after configuration
    end

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

    // Declared before first use on purpose. Referencing tx_ready further down
    // before declaring it created an implicit net; Gowin only warns about that
    // (WARN EX3638 in impl/*_build.log) while iverilog rejects it outright,
    // which is why this never had a top-level testbench. See PROGRESS.md.
    wire tx_ready;
    reg  tx_valid;

    // A byte is handed to uart_tx only on the single cycle where it is both
    // idle and being offered data. tx_ready on its own is high for TWO cycles
    // per byte, which advanced the LFSR twice per transmitted byte and made the
    // FPGA's stream disagree with serial_selftest.py's reference model.
    wire tx_fire = tx_ready && tx_valid;

    wire [7:0] mock_data;
    lfsr8 #(.SEED(SEED)) u_lfsr (
        .clk(clk), .rst_n(rst_n),
        .en(tx_fire && mode_mock), .load_seed(do_resync),
        .value(mock_data)
    );

    // "Real" data source stub — placeholder for Phase 1's actual capture-FIFO output.
    //
    // CMD_RESYNC restarts BOTH sources, not just the LFSR. It previously reloaded
    // the seed only, so REAL mode resumed from wherever the counter happened to
    // be. That was harmless in isolation (a full BURST_LEN=256 burst wraps an
    // 8-bit counter exactly back to 0, so complete bursts looked identical) but
    // it made a *partial* burst leave the design in a state no host command
    // could recover. Phase 1 copies this module, and there "restart the source"
    // has to mean the capture buffer's read pointer -- so resync is defined here
    // as reinitialising every data source, with no exceptions to remember.
    reg [7:0] real_data_stub = 8'h00;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)                     real_data_stub <= 8'h00;
        else if (do_resync)             real_data_stub <= 8'h00;
        else if (tx_fire && !mode_mock) real_data_stub <= real_data_stub + 8'h01;

    wire [7:0] tx_data = mode_mock ? mock_data : real_data_stub;

    // Burst-on-demand, NOT free-running. CMD_RESYNC reloads the LFSR seed and
    // arms exactly BURST_LEN bytes; the line is idle otherwise. Streaming
    // back-to-back forever (the old `tx_valid <= tx_ready`) was unusable for
    // two independent reasons:
    //   1. No inter-frame idle means a receiver has no way to establish
    //      framing -- a data bit's falling edge looks exactly like a start
    //      bit -- and serial_selftest.py's "first byte after resync == SEED"
    //      raced against bytes already in flight.
    //   2. It pins the Arduino bridge's SoftwareSerial receiver at 100% duty;
    //      its bit-banged ISR runs with interrupts disabled for a whole byte
    //      time, so a gap-free stream starves loop() and the hardware USART.
    // BURST_LEN matches serial_selftest.py's default --count.
    localparam [8:0] BURST_LEN = 9'd256;
    reg [8:0] burst_left;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)                          burst_left <= 9'd0;
        else if (do_resync)                  burst_left <= BURST_LEN;
        else if (tx_fire && burst_left != 0) burst_left <= burst_left - 9'd1;

    wire burst_active = (burst_left != 9'd0);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) tx_valid <= 1'b0;
        else tx_valid <= tx_ready && burst_active;

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
        else if (tx_fire) tx_count <= tx_count + 1'b1;

    // Sticky, unambiguous bring-up diagnostic: latches on and stays on the
    // instant a single valid UART byte is received, regardless of its
    // content. Unlike leds[1] (mode), this needs no interpretation and
    // isn't a snapshot of current state -- it only ever goes from off to on.
    reg rx_ever = 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rx_ever <= 1'b0;
        else if (rx_valid) rx_ever <= 1'b1;

    assign leds[0]   = ~heartbeat[23]; // alive heartbeat
    assign leds[1]   = ~mode_mock;     // lit = MOCK mode active (default)
    assign leds[2]   = ~tx_count[7];   // toggles = data actively streaming
    assign leds[3]   = ~rx_ever;       // lit = FPGA has received >=1 valid UART byte since reset
    assign leds[4]   = ~rst;           // DIAGNOSTIC: raw level of pin 88 (lit = pin reads HIGH)
    assign leds[5]   = 1'b1;           // off, reserved for future status bits
endmodule
