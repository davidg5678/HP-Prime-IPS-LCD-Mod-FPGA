`timescale 1ns/1ps
`default_nettype none
//
// PHASE 3: drive the physical parallel-RGB panel.
//
// Orient Display AFY320240A0-3.5INTH-C2 (ST7272A), plugged straight into the
// Tang Nano 20K's own 40-pin FPC connector -- no adapter board. The connectors
// match on 38 of 40 pins and the two that differ are harmless in this
// configuration; the full pin-for-pin analysis is in docs/panel_afy320240a0.md.
//
// Nothing here touches the HP Prime. This target's whole job is to prove the
// panel side works in isolation, on synthetic content, before Phase 4 composes
// it with the capture path. That separation is deliberate: if a combined
// bitstream shows nothing on the panel, "is the panel driver wrong or is the
// capture wrong?" is a two-day question. Answering it once, here, is cheap.
//
// ---------------------------------------------------------------------------
// WHY THE UART SURVIVES INTO A PHASE THAT DOES NOT NEED IT
// ---------------------------------------------------------------------------
// The video path is entirely internal -- pattern generator to pins, no host in
// the loop, which is exactly the bandwidth argument that motivates moving on
// from streaming frames over serial. The UART here carries CONTROL and
// TELEMETRY only, at a few bytes per second:
//
//   * pattern selection, so first light does not need a resynthesis per test
//     image (the mock-mode doctrine in CLAUDE.md: runtime-switchable, never
//     `ifdef build variants);
//   * backlight duty, because the board's boost driver was designed for
//     Sipeed's 4.3" panel and this one's absolute maximum is 50 mA -- being
//     able to turn it down from a keyboard beats desoldering a sense resistor;
//   * the timing the design ACTUALLY emits, measured off its own output pins
//     rather than reported from the counters that generate them (see MONITOR).
//
// ---------------------------------------------------------------------------
// HOST PROTOCOL
// ---------------------------------------------------------------------------
//     0xAA        reset: restart the timing generator at the frame origin and
//                 restart the backlight power-on delay
//     0x50 'P' +1 select pattern, next byte = pattern index (low 3 bits)
//     0x42 'B' +1 set backlight PWM duty, next byte = 0..255
//     0x4C 'L' +1 status LED row: 0 = heartbeat only (default), non-zero = all
//     0x53 'S'    status: the 16-byte report below
//
// REPORT (16 bytes, little-endian, prefix 'S')
//     0      0xA5 magic
//     1      0x05 protocol version
//     2      status: bit0 pll_lock, bit1 backlight on, bit2 timing running
//     3      pattern index
//     4      backlight duty
//     5      reserved
//     6..7   MEASURED DCLKs per line          expect 371
//     8..9   MEASURED active DCLKs per line   expect 320
//     10..11 MEASURED lines per frame         expect 260
//     12..13 MEASURED active lines per frame  expect 240
//     14..15 frame counter, low 16 bits
//
module lcd_panel_top #(
    // T2 in the datasheet's power-on sequence: >= 250 ms from valid display
    // signals to backlight on. 250 ms at 108 MHz. Overridden by the testbench,
    // which cannot afford to simulate a quarter of a second -- and which
    // separately asserts that THIS default is >= 250 ms, so shrinking it for
    // simulation cannot quietly become shrinking it for hardware.
    parameter integer BL_DELAY_CYCLES = 27_000_000,
    // BACKLIGHT OFF AT POWER-ON. This was 64 (25%) on the reasoning that
    // starting dim is the cheap direction to be wrong in. That reasoning missed
    // a case: with the panel NOT connected -- which is the normal state during
    // bring-up, and was the actual state on 2026-08-03 when an A/B FFC contact
    // mismatch meant nothing was mating -- the LP3320 boost converter sees an
    // OPEN CIRCUIT. Its feedback comes from R31 (5.6 ohm) in series with the
    // panel's LED string, so with no LED current FB never reaches its
    // threshold and the converter drives to maximum trying to regulate,
    // indefinitely, into a 50 V-rated output capacitor.
    //
    // A display driver must not enable a boost converter into a load it cannot
    // detect, and nothing on the 40-pin connector reports back to the FPGA. So
    // the backlight is opt-in: `make lcd-hw BL=255`, once the panel is mated.
    //
    // MEASURED 2026-08-04, and it is the second reason to default to 0: the
    // converter DOES NOT START at 25% duty. A 1 kHz PWM gives a 250 us on-time,
    // shorter than the LP3320's soft-start, so it never reaches regulation and
    // the panel stays dark while the status report cheerfully says `bl_on`.
    // Confirmed from both ends -- it lit immediately when a bitstream that does
    // not drive pin 49 let the board's 27k pull-up hold EN statically high, and
    // it lights at BL=255 (99.6% duty, effectively static). A default that
    // reports "on" while producing no light is worse than one that reports off.
    // See the PWM_PRESCALE note below before trying to make dimming work.
    parameter [7:0]   BL_DUTY_INIT    = 8'd0
) (
    input  wire       clk,       // pin 4, 27 MHz
    input  wire       uart_rx,   // pin 70
    output wire       uart_tx,   // pin 69

    // 40-pin FPC. RGB565 is the BOARD's wiring, not the panel's -- the low
    // colour bits are grounded on the PCB. Index [MSB] is the highest-numbered
    // colour bit at the connector: lcd_r[4] is R7, lcd_r[0] is R3.
    output reg  [4:0] lcd_r,     // pins 38,39,40,41,42 = R7..R3
    output reg  [5:0] lcd_g,     // pins 32,33,34,35,36,37 = G7..G2
    output reg  [4:0] lcd_b,     // pins 27,28,29,30,31 = B7..B3
    output wire       lcd_ck,    // pin 77
    output wire       lcd_hs,    // pin 25, active low
    output wire       lcd_vs,    // pin 26, active low
    output wire       lcd_de,    // pin 48, active high
    output wire       lcd_bl,    // pin 49, backlight regulator enable
    output wire       rgb_led,   // pin 79, onboard WS2812 data -- held dark

    output wire [5:0] leds       // pins 15-20, active-low
);
    localparam integer CLK_HZ = 108_000_000;
    localparam integer BAUD   = 1_000_000;

    localparam [7:0] CMD_RESET = 8'hAA, CMD_PATTERN = 8'h50,
                     CMD_BL    = 8'h42, CMD_STATUS  = 8'h53,
                     CMD_LEDS  = 8'h4C;
    localparam [7:0] HDR_MAGIC = 8'hA5, HDR_VERSION = 8'h05;
    localparam [3:0] HDR_LAST  = 4'd15;

    // ------------------------------------------------------------ clocking
    // 108 MHz, the same domain every other target in this repo runs in, so
    // Phase 4 can compose capture and display without a CDC between them. The
    // 6 MHz DCLK is a phase within that domain, not a second clock -- 108/18 is
    // exact, and a divided clock on generic routing is precisely the mistake
    // boards/tangnano20k/pinout.md documents pin 4 for.
    wire clk_s, pll_lock;
    pll_27_108 u_pll (.clkin(clk), .clkout(clk_s), .lock(pll_lock));

    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;
    always @(posedge clk_s) begin
        if (!pll_lock) begin por_cnt <= 16'd0; rst_n <= 1'b0; end
        else begin
            if (!por_cnt[15]) por_cnt <= por_cnt + 16'd1;
            rst_n <= por_cnt[15];
        end
    end

    // ------------------------------------------------------------- command
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk_s), .rst_n(rst_n), .rx(uart_rx), .data(rx_data), .valid(rx_valid)
    );

    reg       do_reset, do_status;
    reg [2:0] pattern;
    reg [7:0] bl_duty;
    reg       leds_verbose;  // 0 = heartbeat only, 1 = the full status row
    reg [1:0] arg_wait;      // 0 = none, else which command the next byte feeds

    localparam [1:0] ARG_NONE = 2'd0, ARG_PATTERN = 2'd1, ARG_BL = 2'd2,
                     ARG_LEDS = 2'd3;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            do_reset <= 1'b0; do_status <= 1'b0;
            pattern  <= 3'd0; bl_duty  <= BL_DUTY_INIT;
            leds_verbose <= 1'b0;
            arg_wait <= ARG_NONE;
        end else begin
            do_reset <= 1'b0; do_status <= 1'b0;
            if (rx_valid) begin
                if (arg_wait != ARG_NONE) begin
                    case (arg_wait)
                        ARG_BL:      bl_duty      <= rx_data;
                        ARG_LEDS:    leds_verbose <= (rx_data != 8'd0);
                        default:     pattern      <= rx_data[2:0];
                    endcase
                    arg_wait <= ARG_NONE;
                end else case (rx_data)
                    CMD_RESET:   do_reset  <= 1'b1;
                    CMD_STATUS:  do_status <= 1'b1;
                    CMD_PATTERN: arg_wait  <= ARG_PATTERN;
                    CMD_BL:      arg_wait  <= ARG_BL;
                    CMD_LEDS:    arg_wait  <= ARG_LEDS;
                    default: ;
                endcase
            end
        end
    end

    // --------------------------------------------------------- video output
    wire       tg_tick, tg_nxt_de, tg_frame;
    wire [9:0] tg_nxt_x, tg_nxt_y;

    lcd_timing_gen u_tg (
        .clk(clk_s), .rst_n(rst_n), .restart(do_reset),
        .dclk(lcd_ck), .hsync_n(lcd_hs), .vsync_n(lcd_vs), .de(lcd_de),
        .tick(tg_tick), .nxt_de(tg_nxt_de), .nxt_x(tg_nxt_x), .nxt_y(tg_nxt_y),
        .frame_tick(tg_frame)
    );

    wire [4:0] pat_r, pat_b;
    wire [5:0] pat_g;
    test_pattern u_pat (
        .x(tg_nxt_x), .y(tg_nxt_y), .sel(pattern),
        .r(pat_r), .g(pat_g), .b(pat_b)
    );

    // The colour registers update on the same tick as de/hsync/vsync inside the
    // timing generator, so every panel-facing signal transitions together at
    // phase 0 and DCLK's edges sit 4 and 13 phases away from all of them.
    //
    // Driven to 0 outside DE on purpose. The panel does not sample blanking, so
    // this is not required -- but the Prime drives its own bus to 0x00 during
    // blanking (docs/prime_lcd_protocol.md, "Blanking"), and matching that means
    // a Phase 4 loopback capture of our own output is directly comparable with a
    // capture of the calculator's. It also makes a DE-gating error visible as a
    // shifted image rather than as a smear of held-over pixels.
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            lcd_r <= 5'd0; lcd_g <= 6'd0; lcd_b <= 5'd0;
        end else if (tg_tick) begin
            lcd_r <= tg_nxt_de ? pat_r : 5'd0;
            lcd_g <= tg_nxt_de ? pat_g : 6'd0;
            lcd_b <= tg_nxt_de ? pat_b : 5'd0;
        end
    end

    // ----------------------------------------------------------- backlight
    // Datasheet power-on sequence, T2: >= 250 ms from display signal output to
    // backlight on. Free to honour in RTL, since the FPGA owns LCD_BL -- and
    // worth honouring, because the other half of that sequence is already
    // violated: T1 wants >= 10 ms between the panel's internal reset going high
    // and DISP going high, but the board hard-ties DISP to +3V3 so DISP rises
    // WITH VDD. Commodity boards do this routinely and it usually works; if the
    // panel fails to initialise, cutting that trace and driving DISP from pin 52
    // (the one spare FPGA pin) is the first thing to try.
    // Sized as a localparam rather than bit-selecting the integer parameter
    // directly: a part-select on an `integer` parameter is accepted by iverilog
    // and quietly interpreted differently by other tools, and this repo has
    // already been bitten twice by GowinSynthesis and iverilog disagreeing about
    // what a construct means (see the EX3638 / EX2000 note in CLAUDE.md).
    localparam [25:0] BL_DELAY_W = BL_DELAY_CYCLES;

    reg [25:0] bl_cnt;
    reg        bl_ready;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            bl_cnt <= 26'd0; bl_ready <= 1'b0;
        end else if (do_reset) begin
            bl_cnt <= 26'd0; bl_ready <= 1'b0;
        end else if (!bl_ready) begin
            bl_cnt <= bl_cnt + 26'd1;
            if (bl_cnt >= BL_DELAY_W - 26'd1) bl_ready <= 1'b1;
        end
    end

    // ~1 kHz PWM: 108 MHz / 422 / 256 = 999.6 Hz. Fast enough not to flicker,
    // slow enough that the boost converter tracks it. Duty 0 means fully off,
    // which is a legitimate setting -- `bl_on` below reports the enable, not the
    // instantaneous pin level, so a host reading status does not see it blink.
    localparam [8:0] PWM_PRESCALE = 9'd422;
    reg [8:0] pwm_pre;
    reg [7:0] pwm_cnt;
    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            pwm_pre <= 9'd0; pwm_cnt <= 8'd0;
        end else if (pwm_pre >= PWM_PRESCALE - 9'd1) begin
            pwm_pre <= 9'd0;
            pwm_cnt <= pwm_cnt + 8'd1;
        end else begin
            pwm_pre <= pwm_pre + 9'd1;
        end
    end

    wire bl_on = bl_ready && (bl_duty != 8'd0);
    assign lcd_bl = bl_on && (pwm_cnt < bl_duty);

    // ------------------------------------------------------------- MONITOR
    // Measures the timing the design ACTUALLY emits, by watching its own output
    // pins -- not by reporting the counters that generate them.
    //
    // That distinction is the whole value. A report derived from `hc`/`vc`
    // inside lcd_timing_gen would agree with the parameters by construction and
    // would still agree if the output registers, the DE gating or the DCLK phase
    // were wrong. This counts DCLK RISING EDGES on lcd_ck between lcd_hs falling
    // edges, which is what a panel does, so it is an independent check in the
    // same sense that docs/verification.md means when it says to assert on
    // values recovered from the design rather than on the constants you believe
    // you set. It is also what will still be meaningful in Phase 4, when the
    // pixel source is SDRAM and the timing has to hold under refresh stalls.
    reg        ck_d, hs_d, vs_d;
    reg [15:0] h_run, h_act, v_run, v_act;
    reg [15:0] h_total_m, h_active_m, v_total_m, v_active_m;
    reg [15:0] frame_cnt;

    wire ck_rise = lcd_ck && !ck_d;
    wire hs_fall = !lcd_hs && hs_d;
    wire vs_fall = !lcd_vs && vs_d;

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            ck_d <= 1'b1; hs_d <= 1'b0; vs_d <= 1'b0;
            h_run <= 16'd0; h_act <= 16'd0; v_run <= 16'd0; v_act <= 16'd0;
            h_total_m <= 16'd0; h_active_m <= 16'd0;
            v_total_m <= 16'd0; v_active_m <= 16'd0;
            frame_cnt <= 16'd0;
        end else begin
            ck_d <= lcd_ck; hs_d <= lcd_hs; vs_d <= lcd_vs;

            if (ck_rise) begin
                h_run <= h_run + 16'd1;
                if (lcd_de) h_act <= h_act + 16'd1;
            end

            // A line ends at each HSYNC falling edge. VSYNC falls coincident
            // with one of them (both derive from the same wrap in
            // lcd_timing_gen), so the frame-end case is nested inside the
            // line-end case -- writing them as two independent `if`s would let
            // v_run be both incremented and cleared in the same cycle, and the
            // later assignment would silently win.
            if (hs_fall) begin
                h_total_m  <= h_run;
                // Latched only on lines that HAD active pixels. Every line has
                // the same 371 DCLKs, so h_total_m is meaningful whenever it is
                // read -- but 20 lines per frame are vertical blanking, where
                // the active count is legitimately 0. Latching unconditionally
                // meant the reported figure depended on whether the host's
                // status request happened to land during blanking, i.e. on
                // timing luck: a `make lcd-hw` that passes or fails at random.
                // Found in simulation, where the read landed in blanking and
                // reported 0 active DCLKs while correctly reporting 240 active
                // lines -- a contradiction that could only come from the latch
                // condition, not from the counter.
                if (h_act != 16'd0) h_active_m <= h_act;
                h_run <= 16'd0;
                h_act <= 16'd0;
                if (vs_fall) begin
                    v_total_m  <= v_run + 16'd1;
                    v_active_m <= v_act + ((h_act != 16'd0) ? 16'd1 : 16'd0);
                    v_run <= 16'd0;
                    v_act <= 16'd0;
                    frame_cnt <= frame_cnt + 16'd1;
                end else begin
                    v_run <= v_run + 16'd1;
                    if (h_act != 16'd0) v_act <= v_act + 16'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------ reply TX
    wire      tx_ready;
    reg       tx_valid;
    wire      tx_fire = tx_ready && tx_valid;
    reg       sending;
    reg [3:0] hdr_i;

    reg [7:0] hdr_byte;
    always @(*) begin
        case (hdr_i)
            4'd0:  hdr_byte = HDR_MAGIC;
            4'd1:  hdr_byte = HDR_VERSION;
            4'd2:  hdr_byte = {5'b0, (frame_cnt != 16'd0), bl_on, pll_lock};
            4'd3:  hdr_byte = {5'b0, pattern};
            4'd4:  hdr_byte = bl_duty;
            4'd5:  hdr_byte = 8'h00;
            4'd6:  hdr_byte = h_total_m[7:0];
            4'd7:  hdr_byte = h_total_m[15:8];
            4'd8:  hdr_byte = h_active_m[7:0];
            4'd9:  hdr_byte = h_active_m[15:8];
            4'd10: hdr_byte = v_total_m[7:0];
            4'd11: hdr_byte = v_total_m[15:8];
            4'd12: hdr_byte = v_active_m[7:0];
            4'd13: hdr_byte = v_active_m[15:8];
            4'd14: hdr_byte = frame_cnt[7:0];
            default: hdr_byte = frame_cnt[15:8];
        endcase
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) tx_valid <= 1'b0;
        else        tx_valid <= tx_ready && sending;
    end

    always @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            sending <= 1'b0; hdr_i <= 4'd0;
        end else if (do_status) begin
            sending <= 1'b1; hdr_i <= 4'd0;
        end else if (sending && tx_fire) begin
            if (hdr_i == HDR_LAST) sending <= 1'b0;
            else                   hdr_i   <= hdr_i + 4'd1;
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk_s), .rst_n(rst_n),
        .data(hdr_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    // ---------------------------------------------------------------- LEDs
    // NOTE: leds[0..3] are pins 15-18, which the board ALSO wires to the FPC
    // connector as LCD_INT0..3 (positions 37-40). On this panel those four
    // positions are XR/YD/XL/YU -- resistive-touch pins that the datasheet
    // marks NC, with nothing connected at the far end. Driving them is
    // therefore harmless here. It would NOT be on a panel with resistive touch,
    // and Phase 4 should re-check this before adding any panel-side input.
    reg [25:0] heartbeat;
    always @(posedge clk_s or negedge rst_n)
        if (!rst_n) heartbeat <= 26'd0; else heartbeat <= heartbeat + 26'd1;

    reg rx_ever;
    always @(posedge clk_s or negedge rst_n)
        if (!rst_n) rx_ever <= 1'b0; else if (rx_valid) rx_ever <= 1'b1;

    // Active-low. leds[0] is the heartbeat and is ALWAYS driven, even in the
    // quiet default: docs/verification.md's whole argument for a liveness
    // indicator is that it has to work when the serial link does not, and a
    // board with every LED dark cannot be distinguished from a board that is
    // not configured. It blinks at ~1.6 Hz, which is not what anyone means by
    // obnoxious.
    //
    // leds[1..5] carry the status row and default OFF, because the 16-byte
    // report over UART says everything they say and says it precisely.
    // `make lcd-hw LEDS=on` brings them back.
    assign leds[0] = ~heartbeat[25];        // alive
    assign leds[1] = leds_verbose ? ~pll_lock              : 1'b1;
    assign leds[2] = leds_verbose ? ~(frame_cnt != 16'd0)  : 1'b1;
    assign leds[3] = leds_verbose ? ~bl_ready              : 1'b1;
    assign leds[4] = leds_verbose ? ~rx_ever               : 1'b1;
    assign leds[5] = leds_verbose ? ~lcd_de                : 1'b1;

    // The onboard WS2812 latches its colour and holds it, so an unassigned
    // pin 79 floats, picks up noise and leaves the LED lit at some arbitrary
    // bright colour. Sending it zeros continuously is the only thing that makes
    // it dark. See src/common/ws2812_off.v -- and note this pin is probe[8]
    // (the Prime's D4) in every capture target, so Phase 4 cannot do this.
    ws2812_off u_rgb (.clk(clk_s), .rst_n(rst_n), .dout(rgb_led));
endmodule
`default_nettype wire
