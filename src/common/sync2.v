`timescale 1ns/1ps
`default_nettype none
//
// N-bit two-flop synchroniser for asynchronous inputs.
//
// Every signal entering the sample-clock domain from outside it goes through
// one of these. That includes the MOCK video generator's outputs even though
// they are already synchronous to `clk`: the mock/real mux sits UPSTREAM of
// this module on purpose, so both sources traverse byte-for-byte identical
// logic on their way into the capture engine. A mock path that skips the
// synchroniser is a mock path that does not test the synchroniser.
//
module sync2 #(
    parameter integer W = 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] d,
    output reg  [W-1:0] q
);
    reg [W-1:0] meta;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta <= {W{1'b0}};
            q    <= {W{1'b0}};
        end else begin
            meta <= d;
            q    <= meta;
        end
    end
endmodule
`default_nettype wire
