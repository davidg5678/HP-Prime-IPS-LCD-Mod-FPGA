`timescale 1ns/1ps
//
// Top-level testbench for la_capture_top -- Phase 1's logic analyser.
//
// Exists because proto-phase-1 proved the point the hard way: uart_tx and
// uart_rx had a PASSING loopback test the entire time the top level was
// unbuildable. Module tests verify the parts you thought about; this verifies
// the assumptions between them. See docs/verification.md.
//
// What it checks, all over the real UART wire rather than by peeking at
// internal state:
//   1. Recovered baud on uart_tx -- proves the rPLL wrapper really produced
//      108 MHz and that uart_tx's DIV followed it. Measured from the design's
//      own output, not asserted against the constant we believe we set.
//   2. Status reply framing: magic, version, power-on state.
//   3. MOCK capture with an immediate trigger, then a full drain, decoded back
//      into video timing and checked against the generator's parameters --
//      DOTCLK period, line period, DE width, and the R/G/B test pattern.
//   4. REAL capture with a genuine edge trigger and pre-trigger history. Uses
//      the REAL path precisely because the testbench can then control the
//      stimulus: the mock frame is ~1.9 us long while a UART command byte
//      takes 10 us, so the host cannot control mock frame phase at all and an
//      edge-trigger test against MOCK would be a coin flip.
//   5. CMD_RESET aborts an armed capture.
//
// The mock frame here is far smaller than the synthesis default (2 px x 3
// lines vs 32 x 8) so a simulation covers whole frames in reasonable time.
// DEPTH is likewise 256 rather than 32768: a drain is 2 bytes per sample at
// 1 Mbaud, so the shipped depth would be 655 ms of simulated UART per drain.
// Buffer depth is not where the bugs are -- framing, trigger semantics and
// pointer arithmetic are, and those are exercised identically at 256.
//
module tb_la_capture;
    // ---------------------------------------------------------- parameters
    localparam integer DEPTH      = 256;
    localparam integer DOTCLK_DIV = 4;
    localparam integer H_TOTAL    = 10;
    localparam integer H_SYNC     = 1;
    localparam integer H_START    = 2;
    localparam integer H_ACTIVE   = 6;   // 2 pixels x 3 components
    localparam integer V_TOTAL    = 5;
    localparam integer V_SYNC     = 1;
    localparam integer V_START    = 1;
    localparam integer V_ACTIVE   = 3;

    localparam integer XPIX = H_ACTIVE / 3;

    localparam real CLK_NS = 1000.0 / 27.0;   // 27 MHz reference, 37.037 ns
    localparam real BIT_NS = 1000.0;          // 1 Mbaud

    localparam [7:0] CMD_RESET  = 8'hAA;
    localparam [7:0] CMD_MOCK   = 8'h4D;
    localparam [7:0] CMD_REAL   = 8'h52;
    localparam [7:0] CMD_ARM    = 8'h41;
    localparam [7:0] CMD_STATUS = 8'h53;
    localparam [7:0] CMD_DRAIN  = 8'h44;
    localparam [7:0] CMD_TRIG   = 8'h54;
    localparam [7:0] CMD_POST   = 8'h50;
    localparam [7:0] CMD_EDGE   = 8'h45;
    localparam [7:0] CMD_LEVEL  = 8'h4C;
    localparam [7:0] CMD_READ   = 8'h47;

    // Channel positions within a sample.
    localparam integer C_DOTCLK = 0;
    localparam integer C_HSYNC  = 1;
    localparam integer C_VSYNC  = 2;
    localparam integer C_DE     = 3;

    // ------------------------------------------------------------- signals
    reg         clk = 1'b0;
    reg         rx  = 1'b1;      // host -> FPGA
    wire        tx;              // FPGA -> host
    reg  [11:0] probe = 12'h004; // bit2 (VSYNC position) idles high
    wire [5:0]  leds;

    integer errors = 0;

    // Free-running walking-1 driver for the channel-mapping check. Runs as its
    // own process because a UART command byte takes 10 us while the whole
    // capture window is 2.4 us -- the testbench cannot drive a pattern "after
    // arming", the capture is long over by then. Cycling continuously instead
    // guarantees the window contains a complete walk wherever it lands.
    reg     walk_en = 1'b0;
    integer wk;
    always begin
        if (walk_en) begin
            for (wk = 0; wk < 12; wk = wk + 1) begin
                probe = 12'd1 << wk;
                // 80 ns per step => a 12-step cycle is 0.96 us. The capture
                // window is 256 samples = 2.37 us, which is more than TWICE the
                // cycle -- that is the condition for a complete walk to fall
                // inside the window regardless of phase. At 140 ns the window
                // was only 1.4 cycles and the check failed intermittently on
                // phase alone. Still ~8.6 samples per step, far more than the
                // synchroniser needs.
                #80.0;
            end
        end else begin
            #100.0;
        end
    end

    always #(CLK_NS/2.0) clk = ~clk;

    la_capture_top #(
        .DEPTH(DEPTH), .DOTCLK_DIV(DOTCLK_DIV),
        .H_TOTAL(H_TOTAL), .H_SYNC(H_SYNC), .H_START(H_START), .H_ACTIVE(H_ACTIVE),
        .V_TOTAL(V_TOTAL), .V_SYNC(V_SYNC), .V_START(V_START), .V_ACTIVE(V_ACTIVE)
    ) dut (
        .clk(clk), .uart_rx(rx), .uart_tx(tx), .probe(probe), .leds(leds)
    );

    // --------------------------------------------------- watchdog (clocks!)
    // Counted in clock cycles, not as a #delay: the required ceiling expressed
    // in ps overflows Verilog's default 32-bit unsized integer literal, which
    // silently produces a watchdog that fires almost immediately.
    integer wd = 0;
    always @(posedge clk) begin
        wd = wd + 1;
        if (wd > 4_000_000) begin
            $display("FAIL: watchdog expired at %0t (deadlock or lost byte)", $realtime);
            $fatal(1);
        end
    end

    // ------------------------------------------------- UART bit-time monitor
    // Recovers the actual baud rate from the narrowest edge-to-edge interval
    // seen on tx. The shortest possible pulse on a UART line is exactly one
    // bit, so this measures the design rather than restating a constant.
    real last_edge = 0.0;
    real min_gap   = 1.0e12;
    always @(tx) begin
        if (last_edge > 0.0) begin
            if (($realtime - last_edge) < min_gap) min_gap = $realtime - last_edge;
        end
        last_edge = $realtime;
    end

    // ---------------------------------------------------------- UART tasks
    task send_byte(input [7:0] b);
        integer i;
        begin
            rx = 1'b0;                       // start
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i];
                #(BIT_NS);
            end
            rx = 1'b1;                       // stop
            #(BIT_NS);
        end
    endtask

    task recv_byte(output [7:0] b);
        integer i;
        begin
            @(negedge tx);                   // start bit
            #(BIT_NS * 1.5);                 // centre of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = tx;
                #(BIT_NS);
            end
        end
    endtask

    // ------------------------------------------------------ reply decoding
    localparam integer HDR_LEN = 10;
    reg [7:0]  hdr [0:HDR_LEN-1];
    reg [15:0] samp [0:DEPTH-1];
    reg [15:0] ref_samp [0:DEPTH-1];

    reg [15:0] r_count;   // total samples in the capture
    reg [15:0] r_trig;
    reg [15:0] r_reply;   // samples actually in THIS reply
    reg [7:0]  r_status;

    task read_header;
        integer i;
        begin
            for (i = 0; i < HDR_LEN; i = i + 1) recv_byte(hdr[i]);
            r_status = hdr[2];
            r_count  = {hdr[5], hdr[4]};
            r_trig   = {hdr[7], hdr[6]};
            r_reply  = {hdr[9], hdr[8]};
            if (hdr[0] !== 8'hA5) begin
                $display("FAIL: header magic 0x%02x, expected 0xa5", hdr[0]);
                errors = errors + 1;
            end
            if (hdr[1] !== 8'h02) begin
                $display("FAIL: header version 0x%02x, expected 0x02", hdr[1]);
                errors = errors + 1;
            end
        end
    endtask

    task read_samples(input integer n);
        integer i;
        reg [7:0] lo, hi;
        begin
            for (i = 0; i < n; i = i + 1) begin
                recv_byte(lo);
                recv_byte(hi);
                samp[i] = {hi, lo};
            end
        end
    endtask

    // Send a command and capture its reply. The fork is load-bearing, not
    // stylistic: uart_rx asserts rx_valid in the MIDDLE of the command's stop
    // bit and the reply's start bit follows a few clocks later -- roughly 400
    // ns before send_byte() returns. Calling read_header() sequentially after
    // send_byte() therefore misses the first byte's falling edge, shifts the
    // whole reply by one byte, and hangs on the last recv_byte. proto-phase-1's
    // testbench hit exactly this and recorded it in PROGRESS.md; it is a
    // property of the protocol, so every command-with-reply pays it.
    task cmd_header(input [7:0] cmd);
        begin
            fork
                send_byte(cmd);
                read_header;
            join
        end
    endtask

    task cmd_drain;
        begin
            fork
                send_byte(CMD_DRAIN);
                begin
                    read_header;
                    read_samples(r_reply);
                end
            join
        end
    endtask

    // Windowed read: header, then `count` samples starting `start` in from the
    // oldest. Same fork rationale as cmd_header.
    task cmd_read(input [15:0] start, input [15:0] count);
        begin
            fork
                begin
                    send_byte(CMD_READ);
                    send_byte(start[7:0]);
                    send_byte(start[15:8]);
                    send_byte(count[7:0]);
                    send_byte(count[15:8]);
                end
                begin
                    // The reply cannot begin until the 5th byte is decoded, so
                    // arm the receiver now and let it wait.
                    read_header;
                    read_samples(r_reply);
                end
            join
        end
    endtask

    task set_trigger(input [15:0] mask, input [15:0] value);
        begin
            send_byte(CMD_TRIG);
            send_byte(mask[7:0]);
            send_byte(mask[15:8]);
            send_byte(value[7:0]);
            send_byte(value[15:8]);
        end
    endtask

    task set_post(input [15:0] n);
        begin
            send_byte(CMD_POST);
            send_byte(n[7:0]);
            send_byte(n[15:8]);
        end
    endtask

    // Poll status until the capture reports full. Bounded, so a capture that
    // never completes fails here with a clear message instead of hanging until
    // the watchdog fires with no context.
    task wait_full(input integer max_polls);
        integer p;
        begin
            p = 0;
            r_status = 8'h00;
            while (!r_status[2] && p < max_polls) begin
                cmd_header(CMD_STATUS);
                p = p + 1;
            end
            if (!r_status[2]) begin
                $display("FAIL: capture never reported full after %0d polls (status=0x%02x)",
                         max_polls, r_status);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------- video decoding
    // Re-derive per-DOTCLK bus values from the oversampled capture exactly as
    // a real decoder would: latch on the DOTCLK rising edge, because the
    // generator presents new data on the falling edge.
    integer nd;
    reg [7:0] d_data  [0:DEPTH-1];
    reg       d_hsync [0:DEPTH-1];
    reg       d_vsync [0:DEPTH-1];
    reg       d_de    [0:DEPTH-1];
    integer   d_at    [0:DEPTH-1];   // sample index of each DOTCLK edge

    task decode_dotclks(input integer n);
        integer i;
        begin
            nd = 0;
            for (i = 1; i < n; i = i + 1) begin
                if (samp[i][C_DOTCLK] && !samp[i-1][C_DOTCLK]) begin
                    d_hsync[nd] = samp[i][C_HSYNC];
                    d_vsync[nd] = samp[i][C_VSYNC];
                    d_de[nd]    = samp[i][C_DE];
                    d_data[nd]  = samp[i][11:4];
                    d_at[nd]    = i;
                    nd = nd + 1;
                end
            end
        end
    endtask

    // ------------------------------------------------------------ main test
    integer i, j;
    integer gap, first_de, run, y_seen, x_seen, comp;
    reg [7:0] expect_byte;
    reg [7:0] b;
    integer pre_ok;

    initial begin
        // Wait out PLL lock (2 us in the model) plus the power-on reset, which
        // is 2^15 cycles of the 108 MHz clock -- 303 us. Talking before this
        // is exactly the failure that cost proto-phase-1 three sessions: the
        // design is in reset, so the line is silent, and the silence gets
        // blamed on the link.
        #400_000.0;

        // ---- 1. status / framing -----------------------------------------
        cmd_header(CMD_STATUS);
        if (r_status[0] !== 1'b0 || r_status[2] !== 1'b0) begin
            $display("FAIL: fresh design reports running=%b full=%b, expected 0/0",
                     r_status[0], r_status[2]);
            errors = errors + 1;
        end
        if (r_status[4] !== 1'b1) begin
            $display("FAIL: power-on source is not MOCK (status=0x%02x)", r_status);
            errors = errors + 1;
        end
        if (r_status[5] !== 1'b1) begin
            $display("FAIL: PLL not locked (status=0x%02x)", r_status);
            errors = errors + 1;
        end

        // ---- 2. recovered baud -------------------------------------------
        // 8 header bytes have been on the wire, so the narrowest gap is a
        // single bit time.
        $display("INFO: narrowest edge-to-edge = %0.0f ps -> baud ~= %0d (expected 1000000)",
                 min_gap * 1000.0, $rtoi(1.0e9 / min_gap));
        if (min_gap < 950.0 || min_gap > 1050.0) begin
            $display("FAIL: recovered bit time %0.1f ns is not 1 Mbaud -- PLL or DIV wrong",
                     min_gap);
            errors = errors + 1;
        end

        // ---- 3. MOCK capture, immediate trigger --------------------------
        send_byte(CMD_RESET);
        send_byte(CMD_MOCK);
        set_post(16'd200);
        set_trigger(16'h0000, 16'h0000);   // mask 0 matches everything => now
        send_byte(CMD_ARM);
        wait_full(20);

        cmd_drain;
        if (r_count !== 16'd201) begin
            $display("FAIL: MOCK drain count %0d, expected 201 (post_len 200 + trigger)",
                     r_count);
            errors = errors + 1;
        end
        if (r_trig !== 16'd0) begin
            $display("FAIL: immediate trigger index %0d, expected 0", r_trig);
            errors = errors + 1;
        end

        decode_dotclks(r_count);
        if (nd < H_TOTAL * 2) begin
            $display("FAIL: only %0d DOTCLK edges recovered from %0d samples, expected >= %0d",
                     nd, r_count, H_TOTAL * 2);
            errors = errors + 1;
        end

        // DOTCLK period, measured in samples, must be DOTCLK_DIV.
        for (i = 1; i < nd; i = i + 1) begin
            gap = d_at[i] - d_at[i-1];
            if (gap !== DOTCLK_DIV) begin
                $display("FAIL: DOTCLK edge %0d came %0d samples after the previous, expected %0d",
                         i, gap, DOTCLK_DIV);
                errors = errors + 1;
                i = nd;
            end
        end

        // Line period, measured in DOTCLKs between HSYNC falling edges.
        j = -1;
        for (i = 1; i < nd; i = i + 1) begin
            if (!d_hsync[i] && d_hsync[i-1]) begin
                if (j >= 0 && (i - j) !== H_TOTAL) begin
                    $display("FAIL: HSYNC period %0d DOTCLKs, expected %0d", i - j, H_TOTAL);
                    errors = errors + 1;
                end
                j = i;
            end
        end
        if (j < 0) begin
            $display("FAIL: no HSYNC falling edge in the capture");
            errors = errors + 1;
        end

        // DE runs: each COMPLETE run must be exactly H_ACTIVE DOTCLKs and
        // carry the documented R/G/B pattern. A run recorded from DOTCLK 0 was
        // already in progress when the capture started and is truncated by
        // construction -- checking it would test where the capture happened to
        // begin, not the design. (The hardware run found this: on real
        // silicon the capture landed mid-DE and reported a run of 25.)
        first_de = -1;
        run = 0;
        for (i = 0; i < nd; i = i + 1) begin
            if (d_de[i]) begin
                if (run == 0) first_de = i;
                run = run + 1;
            end else if (run != 0) begin
                if (first_de == 0) begin
                    // truncated leading run, skip
                end else if (run !== H_ACTIVE) begin
                    $display("FAIL: DE run of %0d DOTCLKs at %0d, expected %0d",
                             run, first_de, H_ACTIVE);
                    errors = errors + 1;
                end else begin
                    // G is the row index, so it identifies which line this is.
                    y_seen = d_data[first_de + 1];
                    for (j = 0; j < H_ACTIVE; j = j + 1) begin
                        x_seen = j / 3;
                        comp   = j % 3;
                        case (comp)
                            0: expect_byte = x_seen[7:0];
                            1: expect_byte = y_seen[7:0];
                            default: expect_byte = x_seen[7:0] ^ y_seen[7:0];
                        endcase
                        if (d_data[first_de + j] !== expect_byte) begin
                            $display("FAIL: pixel data at DOTCLK %0d (x=%0d comp=%0d y=%0d): got 0x%02x expected 0x%02x",
                                     first_de + j, x_seen, comp, y_seen,
                                     d_data[first_de + j], expect_byte);
                            errors = errors + 1;
                            j = H_ACTIVE;
                        end
                    end
                    if (y_seen >= V_ACTIVE) begin
                        $display("FAIL: decoded row %0d outside V_ACTIVE=%0d", y_seen, V_ACTIVE);
                        errors = errors + 1;
                    end
                end
                run = 0;
            end
        end
        if (first_de < 0) begin
            $display("FAIL: DE never asserted in the MOCK capture");
            errors = errors + 1;
        end
        $display("INFO: MOCK capture decoded: %0d DOTCLKs, DE runs of %0d, pattern verified",
                 nd, H_ACTIVE);

        // ---- 3b. windowed read ('G') must reassemble to the same capture ---
        // This is the flow-control path, and it is not a nicety: measured on
        // hardware, an unwindowed 64 KB drain loses 263-1904 bytes at random
        // because nothing throttles the FPGA while the host's driver buffer is
        // full. Chunked reads are how a full-depth capture is actually
        // retrieved, so they need to be exactly equivalent to a full drain.
        for (i = 0; i < r_count; i = i + 1) ref_samp[i] = samp[i];
        j = r_count;                       // remember the total

        cmd_read(16'd0, 16'd64);
        if (r_reply !== 16'd64) begin
            $display("FAIL: windowed read(0,64) replied with %0d samples", r_reply);
            errors = errors + 1;
        end
        for (i = 0; i < 64; i = i + 1)
            if (samp[i] !== ref_samp[i]) begin
                $display("FAIL: windowed read(0,64) sample %0d: got 0x%04x expected 0x%04x",
                         i, samp[i], ref_samp[i]);
                errors = errors + 1;
                i = 64;
            end

        cmd_read(16'd64, 16'd64);
        if (r_reply !== 16'd64) begin
            $display("FAIL: windowed read(64,64) replied with %0d samples", r_reply);
            errors = errors + 1;
        end
        for (i = 0; i < 64; i = i + 1)
            if (samp[i] !== ref_samp[64 + i]) begin
                $display("FAIL: windowed read(64,64) sample %0d: got 0x%04x expected 0x%04x",
                         i, samp[i], ref_samp[64 + i]);
                errors = errors + 1;
                i = 64;
            end

        // Deliberately over-ask: 190 + 100 runs off the end of a 201-sample
        // capture. The reply must be clamped to 11 AND say so, because a host
        // that trusts its own request would otherwise block forever waiting for
        // samples that are never coming.
        cmd_read(16'd190, 16'd100);
        if (r_reply !== 16'd11) begin
            $display("FAIL: over-length read(190,100) of a %0d-sample capture replied %0d, expected 11",
                     j, r_reply);
            errors = errors + 1;
        end else begin
            for (i = 0; i < 11; i = i + 1)
                if (samp[i] !== ref_samp[190 + i]) begin
                    $display("FAIL: clamped read sample %0d: got 0x%04x expected 0x%04x",
                             i, samp[i], ref_samp[190 + i]);
                    errors = errors + 1;
                    i = 11;
                end
        end
        $display("INFO: windowed reads reassemble the capture and clamp an over-ask to 11");

        // ---- 4. REAL capture, edge trigger, pre-trigger history ----------
        // Driven from the testbench so the trigger instant is deterministic,
        // which it could never be against the free-running mock generator.
        send_byte(CMD_RESET);
        send_byte(CMD_REAL);
        probe = 12'h004;                     // bit2 high: trigger not yet true
        set_post(16'd100);
        set_trigger(16'h0004, 16'h0000);     // fire when bit2 falls
        send_byte(CMD_ARM);

        // Let real pre-trigger history accumulate before the edge.
        #(BIT_NS * 30);
        probe = 12'h000;                     // the edge

        wait_full(20);
        cmd_drain;
        if (r_status[1] !== 1'b1) begin
            $display("FAIL: REAL capture reports triggered=0 (status=0x%02x)", r_status);
            errors = errors + 1;
        end

        if (r_trig == 0) begin
            $display("FAIL: trigger landed at index 0 -- no pre-trigger history was kept");
            errors = errors + 1;
        end else begin
            if (samp[r_trig][C_VSYNC] !== 1'b0) begin
                $display("FAIL: sample at trig_index %0d has bit2=%b, expected 0",
                         r_trig, samp[r_trig][C_VSYNC]);
                errors = errors + 1;
            end
            if (samp[r_trig-1][C_VSYNC] !== 1'b1) begin
                $display("FAIL: sample before trig_index has bit2=%b, expected 1 -- trigger is not edge-sensitive",
                         samp[r_trig-1][C_VSYNC]);
                errors = errors + 1;
            end
            // Every pre-trigger sample must show the pre-edge level.
            pre_ok = 1;
            for (i = 0; i < r_trig; i = i + 1)
                if (samp[i][C_VSYNC] !== 1'b1) pre_ok = 0;
            if (!pre_ok) begin
                $display("FAIL: pre-trigger samples are not all at the pre-edge level");
                errors = errors + 1;
            end
            $display("INFO: REAL capture: %0d samples, trigger at %0d, %0d samples of pre-trigger history",
                     r_count, r_trig, r_trig);
        end

        // ---- 4b. channel mapping: every probe pin -> its own sample bit ---
        // Nothing else in this file toggles sample bits 5..11. The MOCK pattern
        // cannot: its frame is 32 px x 8 lines, so x <= 31 and y <= 7 and the
        // top three data bits are always zero. Check 4 drives only bit 2. A
        // transposition among the upper data channels would therefore pass
        // every other test in this file and only show up as garbled pixels
        // after twelve wires had been soldered to a calculator.
        send_byte(CMD_RESET);
        send_byte(CMD_REAL);
        walk_en = 1'b1;
        set_post(16'd255);
        set_trigger(16'h0000, 16'h0000);   // trigger immediately
        send_byte(CMD_ARM);
        wait_full(20);
        cmd_drain;

        // Check the ORDER, not merely the presence, of each one-hot value.
        // Presence alone is not discriminating: transposing two channels yields
        // the same SET of values {1,2,4,...,2048}, and a mutation swapping
        // probe[10] and probe[11] passed a presence-only check.
        //
        // Only ONE-HOT samples are considered. The walk changes two bits at
        // once at every step and probe is asynchronous to the sample clock, so
        // sync2 legitimately catches transient samples (both bits high, or
        // both low) at the boundaries. Those are an artefact of the stimulus,
        // not of the design, and filtering them is not the same as ignoring a
        // failure -- a transposed channel still shows up as one-hot values in
        // the wrong ORDER.
        nd = 0;
        for (i = 0; i < r_reply; i = i + 1) begin
            if (samp[i] != 16'd0 && (samp[i] & (samp[i] - 16'd1)) == 16'd0) begin
                if (nd == 0 || d_at[nd-1] !== samp[i]) begin
                    d_at[nd] = samp[i];
                    nd = nd + 1;
                end
            end
        end

        first_de = -1;
        for (i = nd - 12; i >= 0; i = i - 1)
            if (d_at[i] === 32'd1) first_de = i;
        if (first_de < 0) begin
            $display("FAIL: no complete walking-1 sequence in the capture (%0d one-hot values seen)", nd);
            for (i = 0; i < nd; i = i + 1)
                $display("        one-hot[%0d] = 0x%03x", i, d_at[i]);
            errors = errors + 1;
        end else begin
            pre_ok = 1;
            for (i = 0; i < 12; i = i + 1)
                if (pre_ok && d_at[first_de + i] !== (32'd1 << i)) begin
                    $display("FAIL: channel mapping wrong at step %0d: expected sample 0x%03x, got 0x%03x -- probe[%0d] does not land on sample bit %0d",
                             i, (1 << i), d_at[first_de + i], i, i);
                    errors = errors + 1;
                    pre_ok = 0;
                end
            if (pre_ok)
                $display("INFO: channel mapping verified -- all 12 probes land in their own sample bit, in order");
        end
        walk_en = 1'b0;
        probe   = 12'h004;

        // ---- 5. EDGE vs LEVEL trigger ------------------------------------
        // The discriminating case, and the only one that distinguishes them: a
        // condition that is ALREADY TRUE at the instant the capture is armed.
        // LEVEL must fire at once; EDGE must wait for a real transition. A
        // mutation test (deleting the !match_d term) passed every other check
        // in this file, which is how we learned the term was dead code.
        send_byte(CMD_RESET);
        send_byte(CMD_REAL);
        probe = 12'h000;                     // bit2 already low == condition true
        set_post(16'd100);
        set_trigger(16'h0004, 16'h0000);
        send_byte(CMD_EDGE);
        send_byte(CMD_ARM);
        #(BIT_NS * 20);
        cmd_header(CMD_STATUS);
        if (r_status[6] !== 1'b1) begin
            $display("FAIL: CMD_EDGE not reflected in status (0x%02x)", r_status);
            errors = errors + 1;
        end
        if (r_status[1] !== 1'b0) begin
            $display("FAIL: EDGE trigger fired on a condition already true at arm time (status=0x%02x)",
                     r_status);
            errors = errors + 1;
        end
        if (r_status[0] !== 1'b1) begin
            $display("FAIL: EDGE capture is not running while waiting for its edge (status=0x%02x)",
                     r_status);
            errors = errors + 1;
        end
        probe = 12'h004;                     // leave the condition
        #(BIT_NS * 5);
        probe = 12'h000;                     // genuine transition into it
        wait_full(20);
        if (r_status[1] !== 1'b1) begin
            $display("FAIL: EDGE trigger did not fire on a real transition (status=0x%02x)",
                     r_status);
            errors = errors + 1;
        end
        $display("INFO: EDGE trigger held off an already-true condition, then fired on the transition");
        send_byte(CMD_LEVEL);

        // ---- 6. CMD_RESET aborts an armed capture ------------------------
        probe = 12'h004;
        set_trigger(16'h0004, 16'h0000);     // will not fire while bit2 is high
        send_byte(CMD_ARM);
        cmd_header(CMD_STATUS);
        if (r_status[0] !== 1'b1) begin
            $display("FAIL: after ARM the capture is not running (status=0x%02x)", r_status);
            errors = errors + 1;
        end
        send_byte(CMD_RESET);
        cmd_header(CMD_STATUS);
        if (r_status[0] !== 1'b0 || r_status[2] !== 1'b0) begin
            $display("FAIL: CMD_RESET did not abort the capture (status=0x%02x)", r_status);
            errors = errors + 1;
        end

        // ---- verdict ------------------------------------------------------
        if (errors == 0) begin
            $display("PASS: la_capture top-level, baud + framing + MOCK pattern + windowed reads + channel mapping + pre-trigger history + EDGE/LEVEL trigger + abort verified");
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1);
        end
    end
endmodule
