`timescale 1ns/1ps
`default_nettype none
//
// SUMP/OLS-style capture-then-drain logic analyser core.
//
// Live streaming is not an option and that is what shapes this whole module:
// 12 channels at 108 MHz is 1.3 Gbit/s of raw sample data against a 1 Mbit/s
// UART. So samples land in block RAM at full rate, capture stops, and the host
// drains the buffer afterwards at its leisure.
//
// The buffer is CIRCULAR while armed, which is what buys pre-trigger history:
// by the time the trigger condition occurs the buffer already holds the
// DEPTH-most-recent samples, and capture then runs on for `post_len` more
// before stopping. The host is told where the oldest sample lives and where
// the trigger landed, so it can present the capture with the trigger at a
// known index. For reverse-engineering an unknown bus this matters more than
// it would for ordinary debugging: the interesting question is usually "what
// came immediately BEFORE this edge", and a trigger-then-fill design can only
// ever answer "what came after".
//
// TRIGGER SEMANTICS
//   match = ((sample & trig_mask) == (trig_value & trig_mask))
// and the trigger always fires on a RISING EDGE of `match`. What `trig_edge`
// selects is the value `match_d` is seeded with when the capture is armed:
//
//   trig_edge = 0 (LEVEL): seeded 0, so a condition that is already true at
//       arm time counts as an edge and fires on the first sampled cycle. This
//       also makes trig_mask == 0 -- which matches everything -- mean "trigger
//       immediately", with no separate free-run mode to implement or test.
//
//   trig_edge = 1 (EDGE): seeded with the arm-time value of `match`, so a
//       condition already true when armed does NOT fire; capture waits for a
//       genuine transition into it.
//
// The distinction matters for the job this part is for. "Capture the next
// VSYNC falling edge" is the archetypal request, and if VSYNC happens to be
// low at the instant the host arms, LEVEL mode fires immediately and returns
// a buffer full of the wrong part of the frame -- a failure that looks like
// working equipment. In LEVEL mode `match_d` is provably redundant (a
// mutation test proved it: removing the term changed nothing), so without
// trig_edge this module would be carrying dead logic behind a comment
// claiming a behaviour it did not have.
//
// Total samples retained from the trigger onwards is post_len + 1: the trigger
// sample itself, then post_len more.
//
//
module capture_engine #(
    parameter integer SAMPLE_W = 16,
    parameter integer DEPTH    = 32768,           // MUST be a power of two
    // Derived. Present as a parameter only because Verilog-2001 cannot use a
    // localparam in its own port list. Do not override it.
    parameter integer AW       = $clog2(DEPTH)
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [SAMPLE_W-1:0]  sample,      // already synchronised to clk
    input  wire                 arm,         // 1-cycle pulse: start capturing
    input  wire                 abort,       // 1-cycle pulse: stop, discard

    input  wire [SAMPLE_W-1:0]  trig_mask,
    input  wire [SAMPLE_W-1:0]  trig_value,
    input  wire                 trig_edge,   // 0 = level, 1 = require a transition
    input  wire [AW:0]          post_len,    // post-trigger samples, 0..DEPTH

    output reg                  running,
    output reg                  triggered,
    output reg                  full,        // capture complete, data readable
    output wire                 wrapped,     // buffer filled at least once
    output wire [AW:0]          valid_count, // samples available to drain
    output wire [AW-1:0]        start_ptr,   // address of the oldest sample
    output wire [AW-1:0]        trig_index,  // trigger position within the drain

    input  wire [AW-1:0]        rd_addr,
    output reg  [SAMPLE_W-1:0]  rd_data
);
    // Sized localparam, not a part-select of the integer parameter: slicing a
    // parameter is not portable Verilog-2001.
    localparam [AW:0] DEPTH_W = DEPTH;

    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] trig_ptr;
    reg [AW:0]   fill_count;   // saturates at DEPTH
    reg [AW:0]   post_left;
    reg          match_d;

    wire match     = ((sample & trig_mask) == (trig_value & trig_mask));
    wire trig_fire = running && !triggered && match && !match_d;

    // ---------------------------------------------------------------- memory
    // Deliberately its own always block with NO reset. A memory array cannot
    // be reset anyway, and putting the write inside the async-reset block
    // below is a well-known way to stop a synthesiser inferring block RAM at
    // all -- it would silently fall back to thousands of LUT-based registers
    // and blow the device up. The read register is unreset for the same
    // reason: BSRAM output registers have no async clear, so demanding one
    // pushes the tool out of BSRAM.
    //
    // This is a deliberate, reasoned exception to this repo's "give every
    // register a reset term" rule (see CLAUDE.md). It is safe here because
    // rd_data is only ever consumed after `full`, by which point every address
    // the host can ask for has been written.
    reg [SAMPLE_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (running) mem[wr_ptr] <= sample;
        rd_data <= mem[rd_addr];
    end

    // ----------------------------------------------------------- control FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running    <= 1'b0;
            triggered  <= 1'b0;
            full       <= 1'b0;
            wr_ptr     <= {AW{1'b0}};
            trig_ptr   <= {AW{1'b0}};
            fill_count <= {(AW+1){1'b0}};
            post_left  <= {(AW+1){1'b0}};
            match_d    <= 1'b0;
        end else if (abort) begin
            running    <= 1'b0;
            triggered  <= 1'b0;
            full       <= 1'b0;
            wr_ptr     <= {AW{1'b0}};
            trig_ptr   <= {AW{1'b0}};
            fill_count <= {(AW+1){1'b0}};
            post_left  <= {(AW+1){1'b0}};
            match_d    <= 1'b0;
        end else if (arm) begin
            running    <= 1'b1;
            triggered  <= 1'b0;
            full       <= 1'b0;
            wr_ptr     <= {AW{1'b0}};
            trig_ptr   <= {AW{1'b0}};
            fill_count <= {(AW+1){1'b0}};
            post_left  <= {(AW+1){1'b0}};
            // LEVEL seeds 0 so an already-true condition counts as an edge and
            // fires at once; EDGE seeds the arm-time match so it does not.
            match_d    <= trig_edge ? match : 1'b0;
        end else if (running) begin
            match_d <= match;
            wr_ptr  <= wr_ptr + 1'b1;   // AW-bit wraparound is the circular buffer
            if (fill_count != DEPTH_W) fill_count <= fill_count + 1'b1;

            if (!triggered) begin
                if (trig_fire) begin
                    triggered <= 1'b1;
                    trig_ptr  <= wr_ptr;
                    post_left <= post_len;
                    if (post_len == {(AW+1){1'b0}}) begin
                        running <= 1'b0;
                        full    <= 1'b1;
                    end
                end
            end else begin
                post_left <= post_left - 1'b1;
                if (post_left == {{AW{1'b0}}, 1'b1}) begin   // == 1
                    running <= 1'b0;
                    full    <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------ drain view
    //
    // REGISTERED, and that is a timing fix rather than a style preference.
    // Computing these combinationally put fill_count at the head of the
    // design's critical path: fill_count -> DEPTH comparator -> start_ptr mux
    // -> rd_addr adder -> BSRAM address, and in parallel -> valid_count ->
    // header byte mux -> uart_tx's shift register. That measured Fmax 110.4 MHz
    // against a 108 MHz requirement -- met, but only 2.2% of margin on a design
    // Phase 4 has to build on top of. Registering the view moved the endpoint
    // to a flip-flop and left short paths on both sides.
    //
    // The one- and two-cycle lag this introduces is unobservable. Every
    // consumer is the host, which cannot issue a command and read a reply in
    // under a UART byte time -- 108 clocks at 1 Mbaud.
    wire          wrapped_c   = (fill_count == DEPTH_W);
    // DEPTH is a power of two, so AW-bit wraparound IS the modulo.
    wire [AW-1:0] start_ptr_c = wrapped_c ? wr_ptr : {AW{1'b0}};

    reg          wrapped_r;
    reg [AW:0]   valid_count_r;
    reg [AW-1:0] start_ptr_r;
    reg [AW-1:0] trig_index_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wrapped_r     <= 1'b0;
            valid_count_r <= {(AW+1){1'b0}};
            start_ptr_r   <= {AW{1'b0}};
            trig_index_r  <= {AW{1'b0}};
        end else begin
            wrapped_r     <= wrapped_c;
            valid_count_r <= fill_count;
            start_ptr_r   <= start_ptr_c;
            // Deliberately off the REGISTERED start_ptr, not start_ptr_c:
            // chaining the comparator, mux and a 15-bit subtract into one
            // cycle would just recreate the long path one stage further along.
            trig_index_r  <= trig_ptr - start_ptr_r;
        end
    end

    assign wrapped     = wrapped_r;
    assign valid_count = valid_count_r;
    assign start_ptr   = start_ptr_r;
    assign trig_index  = trig_index_r;
endmodule
`default_nettype wire
