`timescale 1ns/1ps
`default_nettype none
//
// Phase 1 -- logic analyser for the HP Prime's serial-RGB LCD bus.
//
// Captures 12 channels into block RAM at 108 MHz, then drains the buffer to
// the host over the same 1 Mbaud BL616 UART link proto-phase-1 established.
// Follows the mock/real runtime-mux convention from CLAUDE.md: a synthetic
// video-timing generator and the physical probe pins both live in this one
// bitstream and are selected by a command byte, so an agent can validate the
// entire capture-trigger-drain-decode path with no calculator attached and no
// re-synthesis to switch back.
//
// CHANNEL MAP (probe[n] -> sample bit n; see boards/tangnano20k/pinout.md)
//     0  DOTCLK      pin 77
//     1  HSYNC       pin 25
//     2  VSYNC       pin 26
//     3  DE          pin 48
//     4..11  D0..D7  pins 27, 28, 29, 30, 31, 71, 72, 73
//
// HOST PROTOCOL -- single command bytes, two of them followed by a payload.
//     0xAA          reset: abort capture, restart the mock source, idle the drain
//     0x4D  'M'     select MOCK source (default at power-on)
//     0x52  'R'     select REAL probe pins
//     0x41  'A'     arm the capture
//     0x53  'S'     status: reply with the 8-byte header alone
//     0x44  'D'     drain: reply with the header, then valid_count 16-bit samples
//     0x54  'T' +4  set trigger: mask_lo mask_hi value_lo value_hi (little-endian)
//     0x50  'P' +2  set post-trigger length in samples: len_lo len_hi
//     0x45  'E'     EDGE trigger: require a transition into the condition
//     0x4C  'L'     LEVEL trigger (default): fire if the condition already holds
//     0x47  'G' +4  read a WINDOW: start_lo start_hi count_lo count_hi
//
// WHY A WINDOWED READ EXISTS. 'D' streams the whole buffer -- 64 KB at the
// default depth, 0.66 s of continuous 1 Mbaud with no flow control. Measured on
// real hardware, that loses bytes: four consecutive full drains came up 263 to
// 1904 bytes short, non-deterministically, because nothing stops the FPGA
// transmitting while the host's driver buffer is full. 'G' lets the host bound
// what is in flight -- ask for 4096 samples, read them, ask again -- so the
// FPGA never sends more than the host has committed to receive and a lost
// chunk is retryable rather than fatal. 'D' is kept because it is exactly
// G(0, valid_count) and is convenient for small captures.
//
// REPLY HEADER (10 bytes, little-endian; prefixes 'S', 'D' and 'G')
//     0  0xA5 magic
//     1  0x02 protocol version
//     2  status: bit0 running, bit1 triggered, bit2 full, bit3 wrapped,
//               bit4 mode_mock, bit5 pll_lock, bit6 trig_edge
//     3  reserved, 0x00
//     4..5  valid_count  (total samples in the capture)
//     6..7  trig_index   (index of the trigger sample within the capture)
//     8..9  reply_count  (samples that actually follow THIS reply)
// Sample bytes follow low-byte-first; only bits 11:0 are meaningful.
//
// reply_count is separate from valid_count on purpose: a windowed request that
// runs off the end of the capture is clamped, and without an explicit count of
// what was actually sent the host would sit waiting for samples that are never
// coming and then resynchronise on garbage. The header as a whole exists
// because proto-phase-1's hardest bug was a receiver with no way to establish
// framing.
//
module la_capture_top #(
    // DEPTH must be a power of two and <= 32768 (valid_count must fit the
    // header's 16-bit field). 32768 x 16 bits = 512 Kbit of the part's 828
    // Kbit, leaving room for Phase 4. At 108 MHz it is 303 us of capture --
    // several complete mock frames, or roughly five lines of a real panel.
    parameter integer DEPTH      = 32768,
    // Mock video timing, forwarded to video_timing_gen. The testbench shrinks
    // these so a simulation can cover whole frames.
    parameter integer DOTCLK_DIV = 8,
    parameter integer H_TOTAL    = 120,
    parameter integer H_SYNC     = 6,
    parameter integer H_START    = 18,
    parameter integer H_ACTIVE   = 96,
    parameter integer V_TOTAL    = 10,
    parameter integer V_SYNC     = 1,
    parameter integer V_START    = 2,
    parameter integer V_ACTIVE   = 8
) (
    input  wire        clk,       // pin 4, 27 MHz onboard oscillator (LPLL1_T_in)
    input  wire        uart_rx,   // pin 70, onboard BL616 UART, host -> FPGA
    output wire        uart_tx,   // pin 69, onboard BL616 UART, FPGA -> host
    input  wire [11:0] probe,     // see CHANNEL MAP above
    output wire [5:0]  leds       // pins 15-20, active low
);
    localparam integer CLK_HZ   = 108_000_000;
    localparam integer BAUD     = 1_000_000;   // 108 / 1 = DIV 108 exactly
    localparam integer SAMPLE_W = 16;
    localparam integer AW       = $clog2(DEPTH);

    localparam [7:0] CMD_RESET  = 8'hAA;
    localparam [7:0] CMD_MOCK   = 8'h4D; // 'M'
    localparam [7:0] CMD_REAL   = 8'h52; // 'R'
    localparam [7:0] CMD_ARM    = 8'h41; // 'A'
    localparam [7:0] CMD_STATUS = 8'h53; // 'S'
    localparam [7:0] CMD_DRAIN  = 8'h44; // 'D'
    localparam [7:0] CMD_TRIG   = 8'h54; // 'T', 4 payload bytes
    localparam [7:0] CMD_POST   = 8'h50; // 'P', 2 payload bytes
    localparam [7:0] CMD_EDGE   = 8'h45; // 'E'
    localparam [7:0] CMD_LEVEL  = 8'h4C; // 'L'
    localparam [7:0] CMD_READ   = 8'h47; // 'G', 4 payload bytes

    localparam [7:0]  HDR_MAGIC   = 8'hA5;
    localparam [7:0]  HDR_VERSION = 8'h02;
    localparam [3:0]  HDR_LAST    = 4'd9;   // 10-byte header
    // Sized localparams rather than part-selects of the integer parameter:
    // slicing a parameter (DEPTH[15:0]) is not portable Verilog-2001.
    localparam [15:0] DEPTH16      = DEPTH;
    localparam [AW:0] DEPTH_AW     = DEPTH;
    localparam [AW:0] POST_DEFAULT = (DEPTH * 3) / 4;

    // ------------------------------------------------------------ clocking
    wire clk_s;      // 108 MHz sample/system clock
    wire pll_lock;

    pll_27_108 u_pll (.clkin(clk), .clkout(clk_s), .lock(pll_lock));

    // Power-on reset, held until the PLL reports lock. This block is itself
    // unreset -- it is the reset generator -- but unlike proto-phase-1's
    // free-running heartbeat that is not a blind spot: pll_lock gates it, so
    // "out of reset" genuinely implies "clock is good".
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;
    always @(posedge clk_s) begin
        if (!pll_lock) begin
            por_cnt <= 16'd0;
            rst_n   <= 1'b0;
        end else begin
            if (!por_cnt[15]) por_cnt <= por_cnt + 16'd1;
            rst_n <= por_cnt[15];   // releases ~303 us after lock
        end
    end

    // ------------------------------------------------------------- command
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk_s), .rst_n(rst_n), .rx(uart_rx),
        .data(rx_data), .valid(rx_valid)
    );

    // Declared ahead of first use. Referencing a signal before its declaration
    // creates an implicit net that Gowin only warns about (WARN EX3638) while
    // iverilog rejects outright -- the bug that kept proto-phase-1's top level
    // from ever being simulated. `default_nettype none at the top of this file
    // now makes that a hard error in both tools.
    wire         cap_running;
    wire         cap_triggered;
    wire         cap_full;
    wire         cap_wrapped;
    wire [AW:0]  cap_valid_count;
    wire [AW-1:0] cap_start_ptr;
    wire [AW-1:0] cap_trig_index;

    reg          mode_mock;
    reg  [15:0]  trig_mask;
    reg  [15:0]  trig_value;
    reg          trig_edge;
    reg  [AW:0]  post_len;
    reg          do_reset;
    reg          do_arm;
    reg          do_status;
    reg          do_drain;
    reg          do_read;
    reg  [15:0]  read_start;
    reg  [15:0]  read_count;

    reg  [2:0]   arg_left;
    reg  [7:0]   arg_cmd;
    reg  [31:0]  arg_sr;

    // Payload decode. Bytes shift in from the right, so while the LAST byte of
    // a payload is being handled (arg_left == 1) it is still only on rx_data --
    // the non-blocking write to arg_sr above has not taken effect yet. For a
    // 4-byte payload b0..b3 that means, at that moment:
    //     arg_sr[23:16] = b0   arg_sr[15:8] = b1   arg_sr[7:0] = b2   rx_data = b3
    // and for a 2-byte payload b0,b1:
    //     arg_sr[7:0] = b0     rx_data = b1
    // Payload integers are little-endian, so the LOW byte arrives first.
    wire [15:0] arg_first16  = {arg_sr[15:8], arg_sr[23:16]}; // {b1,b0} of a 4-byte payload
    wire [15:0] arg_second16 = {rx_data,      arg_sr[7:0]};   // {b3,b2} of a 4-byte payload
    wire [15:0] arg_pair16   = {rx_data,      arg_sr[7:0]};   // {b1,b0} of a 2-byte payload

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            mode_mock  <= 1'b1;          // MOCK at power-on, per CLAUDE.md
            trig_mask  <= 16'h0000;      // matches everything => trigger at once
            trig_value <= 16'h0000;
            trig_edge  <= 1'b0;          // LEVEL, so mask 0 means "trigger now"
            // 25% pre-trigger by default: enough history to see what preceded
            // the edge, most of the buffer still spent on what followed.
            post_len   <= POST_DEFAULT;
            do_reset   <= 1'b0;
            do_arm     <= 1'b0;
            do_status  <= 1'b0;
            do_drain   <= 1'b0;
            do_read    <= 1'b0;
            read_start <= 16'd0;
            read_count <= 16'd0;
            arg_left   <= 3'd0;
            arg_cmd    <= 8'h00;
            arg_sr     <= 32'h0;
        end else begin
            do_reset  <= 1'b0;
            do_arm    <= 1'b0;
            do_status <= 1'b0;
            do_drain  <= 1'b0;
            do_read   <= 1'b0;

            if (rx_valid) begin
                if (arg_left != 3'd0) begin
                    arg_sr   <= {arg_sr[23:0], rx_data};
                    arg_left <= arg_left - 3'd1;
                    if (arg_left == 3'd1) case (arg_cmd)
                        CMD_TRIG: begin
                            trig_mask  <= arg_first16;
                            trig_value <= arg_second16;
                        end
                        // Clamped rather than wrapped: a host asking for more
                        // post-trigger samples than the buffer holds gets the
                        // buffer, not a silently truncated modulo of it.
                        CMD_POST: post_len <= (arg_pair16 > DEPTH16) ? DEPTH_AW
                                                                      : arg_pair16[AW:0];
                        CMD_READ: begin
                            do_read    <= 1'b1;
                            read_start <= arg_first16;
                            read_count <= arg_second16;
                        end
                        default: ;
                    endcase
                end else case (rx_data)
                    CMD_RESET:  do_reset  <= 1'b1;
                    CMD_MOCK:   mode_mock <= 1'b1;
                    CMD_REAL:   mode_mock <= 1'b0;
                    CMD_EDGE:   trig_edge <= 1'b1;
                    CMD_LEVEL:  trig_edge <= 1'b0;
                    CMD_ARM:    do_arm    <= 1'b1;
                    CMD_STATUS: do_status <= 1'b1;
                    CMD_DRAIN:  do_drain  <= 1'b1;
                    CMD_TRIG:   begin arg_cmd <= CMD_TRIG; arg_left <= 3'd4; end
                    CMD_READ:   begin arg_cmd <= CMD_READ; arg_left <= 3'd4; end
                    CMD_POST:   begin arg_cmd <= CMD_POST; arg_left <= 3'd2; end
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------- sample path
    wire       mock_dotclk, mock_hsync, mock_vsync, mock_de;
    wire [7:0] mock_data;

    video_timing_gen #(
        .DOTCLK_DIV(DOTCLK_DIV),
        .H_TOTAL(H_TOTAL), .H_SYNC(H_SYNC), .H_START(H_START), .H_ACTIVE(H_ACTIVE),
        .V_TOTAL(V_TOTAL), .V_SYNC(V_SYNC), .V_START(V_START), .V_ACTIVE(V_ACTIVE)
    ) u_mock (
        .clk(clk_s), .rst_n(rst_n), .restart(do_reset),
        .dotclk(mock_dotclk), .hsync(mock_hsync), .vsync(mock_vsync),
        .de(mock_de), .data(mock_data)
    );

    wire [11:0] mock_bus = {mock_data, mock_de, mock_vsync, mock_hsync, mock_dotclk};
    // The mux sits UPSTREAM of the synchroniser so mock and real traverse
    // identical logic. A mock path that bypasses sync2 does not test sync2.
    wire [11:0] mux_bus  = mode_mock ? mock_bus : probe;

    wire [11:0] bus_s;
    sync2 #(.W(12)) u_sync (.clk(clk_s), .rst_n(rst_n), .d(mux_bus), .q(bus_s));

    wire [SAMPLE_W-1:0] sample = {4'b0000, bus_s};

    wire [AW-1:0]        rd_addr;
    wire [SAMPLE_W-1:0]  rd_data;

    capture_engine #(.SAMPLE_W(SAMPLE_W), .DEPTH(DEPTH)) u_cap (
        .clk(clk_s), .rst_n(rst_n),
        .sample(sample),
        .arm(do_arm),
        .abort(do_reset),
        .trig_mask(trig_mask),
        .trig_value(trig_value),
        .trig_edge(trig_edge),
        .post_len(post_len),
        .running(cap_running),
        .triggered(cap_triggered),
        .full(cap_full),
        .wrapped(cap_wrapped),
        .valid_count(cap_valid_count),
        .start_ptr(cap_start_ptr),
        .trig_index(cap_trig_index),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    // ------------------------------------------------------------- drain TX
    localparam [1:0] DR_IDLE = 2'd0, DR_HDR = 2'd1, DR_LO = 2'd2, DR_HI = 2'd3;

    reg [1:0]  dr_state;
    reg [3:0]  hdr_i;
    reg [AW:0] samp_i;
    // dr_len is how many samples THIS reply carries: 0 for 'S', valid_count for
    // 'D', and whatever the host asked for (clamped) for 'G'. dr_rdbase is the
    // absolute BSRAM address of the first of them.
    //
    // Both live ONLY in the request pipeline below. An earlier version also
    // reset them in the FSM block above, which iverilog simulated happily and
    // GowinSynthesis rejected outright:
    //   ERROR (EX2000) Net 'dr_base[15]' is constantly driven from multiple places
    // -- the mirror image of the EX3638 lesson in CLAUDE.md, with the
    // permissive and the strict tool swapped. Both directions are real, so
    // neither toolchain alone is sufficient evidence that RTL is well formed.
    reg [AW:0] dr_len;
    // Request pipeline. See the comment above dr_request below.
    reg [AW:0]   rq_start;
    reg [AW:0]   rq_count;
    reg [AW:0]   dr_avail;
    reg [AW-1:0] dr_rdbase;

    wire        tx_ready;
    reg         tx_valid;
    wire        tx_fire = tx_ready && tx_valid;
    wire        dr_busy = (dr_state != DR_IDLE);

    // Zero-extended by OR-ing into a 16-bit zero rather than by replication:
    // at the default DEPTH, AW is 15 and cap_valid_count is already 16 bits,
    // so {{(15-AW){1'b0}}, ...} would be an illegal zero-width replication.
    // This form is correct for every DEPTH from 2 up to 32768.
    wire [15:0] valid_count16 = 16'd0 | cap_valid_count;
    wire [15:0] trig_index16  = 16'd0 | cap_trig_index;
    wire [15:0] reply_count16 = 16'd0 | dr_len;

    // Clamp a windowed request to what the capture actually holds, so a host
    // that over-asks gets a short-but-honest reply (reply_count says so)
    // instead of the FPGA reading past the end of the valid region.
    //
    // PIPELINED OVER THREE CYCLES, and that is a timing fix. Done
    // combinationally -- compare, subtract, compare, mux across 16 bits -- this
    // clamp became the critical path and dropped Fmax to 96.8 MHz against a
    // 108 MHz requirement: 15 setup-violated endpoints on a build that still
    // printed BUILD PASS, and that still passed a room-temperature hardware
    // test. Nothing needs the answer quickly: the earliest consumer is header
    // byte 8 (reply_count), roughly 870 clocks after the request lands, and the
    // DR_HDR -> DR_LO transition is ~1080 clocks out.
    //
    // The stages run unconditionally off the registered request, so they simply
    // settle two cycles after dr_go and then hold.
    wire        dr_go        = do_status || do_drain || do_read;
    wire [15:0] req_start16  = do_read   ? read_start : 16'd0;
    wire [15:0] req_count16  = do_status ? 16'd0
                             : do_read   ? read_count
                                         : valid_count16;

    reg [7:0] hdr_byte;
    always @(*) begin
        case (hdr_i)
            4'd0:    hdr_byte = HDR_MAGIC;
            4'd1:    hdr_byte = HDR_VERSION;
            4'd2:    hdr_byte = {1'b0, trig_edge, pll_lock, mode_mock,
                                 cap_wrapped, cap_full, cap_triggered, cap_running};
            4'd3:    hdr_byte = 8'h00;
            4'd4:    hdr_byte = valid_count16[7:0];
            4'd5:    hdr_byte = valid_count16[15:8];
            4'd6:    hdr_byte = trig_index16[7:0];
            4'd7:    hdr_byte = trig_index16[15:8];
            4'd8:    hdr_byte = reply_count16[7:0];
            default: hdr_byte = reply_count16[15:8];
        endcase
    end

    wire [7:0] tx_byte = (dr_state == DR_HDR) ? hdr_byte
                       : (dr_state == DR_LO)  ? rd_data[7:0]
                       :                        rd_data[15:8];

    // Combinational, so it settles one cycle before rd_data reflects it. That
    // is fine: rd_data is only consumed at a tx_fire, and consecutive fires are
    // at least one UART byte (108 clocks at 1 Mbaud) apart, so a one-cycle
    // BSRAM read latency is invisible here.
    assign rd_addr = dr_rdbase + samp_i[AW-1:0];

    // Registering tx_valid off tx_ready is deliberate and load-bearing.
    // uart_tx latches its input on any cycle where state==IDLE && valid, which
    // can happen a cycle BEFORE its `ready` output rises -- so a level-held
    // valid would be consumed without this FSM ever seeing tx_fire, and the
    // byte would be sent twice. Gating valid on an already-high ready costs one
    // idle cycle per byte out of 108 and makes the handshake unambiguous.
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) tx_valid <= 1'b0;
        else        tx_valid <= tx_ready && dr_busy;
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            dr_state <= DR_IDLE;
            hdr_i    <= 4'd0;
            samp_i   <= {(AW+1){1'b0}};
        end else if (do_reset || do_arm) begin
            // Arming mid-drain abandons the drain; the old buffer is about to
            // be overwritten anyway.
            dr_state <= DR_IDLE;
            hdr_i    <= 4'd0;
            samp_i   <= {(AW+1){1'b0}};
        end else if (dr_go) begin
            dr_state <= DR_HDR;
            hdr_i    <= 4'd0;
            samp_i   <= {(AW+1){1'b0}};
        end else if (tx_fire) begin
            case (dr_state)
                DR_HDR: if (hdr_i == HDR_LAST)
                            dr_state <= (dr_len == {(AW+1){1'b0}}) ? DR_IDLE : DR_LO;
                        else
                            hdr_i <= hdr_i + 4'd1;
                DR_LO:  dr_state <= DR_HI;
                DR_HI:  if (samp_i + 1'b1 == dr_len) begin
                            dr_state <= DR_IDLE;
                        end else begin
                            samp_i   <= samp_i + 1'b1;
                            dr_state <= DR_LO;
                        end
                default: dr_state <= DR_IDLE;
            endcase
        end
    end

    // Stage 1 latches the request (saturating the start), stage 2 derives how
    // much is available from there, stage 3 clamps the length to it. A request
    // with nothing to send lands as dr_len == 0, which reply_count reports
    // honestly -- never a silent zero-length body the host has to infer.
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            rq_start  <= {(AW+1){1'b0}};
            rq_count  <= {(AW+1){1'b0}};
            dr_avail  <= {(AW+1){1'b0}};
            dr_rdbase <= {AW{1'b0}};
            dr_len    <= {(AW+1){1'b0}};
        end else begin
            if (dr_go) begin
                rq_start <= (req_start16 > valid_count16) ? cap_valid_count
                                                          : req_start16[AW:0];
                rq_count <= (req_count16 > DEPTH16) ? DEPTH_AW : req_count16[AW:0];
            end
            dr_avail  <= cap_valid_count - rq_start;
            dr_rdbase <= cap_start_ptr + rq_start[AW-1:0];
            dr_len    <= (rq_count > dr_avail) ? dr_avail : rq_count;
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk_s), .rst_n(rst_n),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready),
        .tx(uart_tx)
    );

    // ---------------------------------------------------------------- LEDs
    // Reset term included on purpose. proto-phase-1's heartbeat was the one
    // register without one, so it blinked happily while the rest of the design
    // sat in reset -- an "is it alive?" light that could not distinguish
    // configured from running. 2^25 at 108 MHz toggles at ~1.6 Hz.
    reg [25:0] heartbeat;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) heartbeat <= 26'd0;
        else        heartbeat <= heartbeat + 26'd1;
    end

    assign leds[0] = ~heartbeat[25];   // alive AND out of reset
    assign leds[1] = ~mode_mock;       // lit = MOCK source selected
    assign leds[2] = ~cap_running;     // lit = armed, sampling
    assign leds[3] = ~cap_full;        // lit = capture complete, data waiting
    assign leds[4] = ~cap_triggered;   // lit = trigger condition seen
    assign leds[5] = ~pll_lock;        // lit = PLL locked
endmodule
`default_nettype wire
