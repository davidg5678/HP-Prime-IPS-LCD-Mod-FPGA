module lfsr8 #(
    parameter [7:0] SEED = 8'h01
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,
    input  wire       load_seed,
    output reg  [7:0] value
);
    // x^8 + x^6 + x^5 + x^4 + 1, maximal-length (period 255)
    wire feedback = value[7] ^ value[5] ^ value[4] ^ value[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          value <= SEED;
        else if (load_seed)  value <= SEED;
        else if (en)         value <= {value[6:0], feedback};
    end
endmodule
