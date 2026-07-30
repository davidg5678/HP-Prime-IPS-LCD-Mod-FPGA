`timescale 1ns/1ps
module uart_tx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 1_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       valid,   // pulse 1 cycle to start a transmission
    output reg        ready,   // high when idle, able to accept new data
    output reg        tx
);
    localparam [15:0] DIV = CLK_HZ / BAUD;
    localparam [1:0] IDLE = 0, START = 1, DATA = 2, STOP = 3;

    reg [1:0]  state = IDLE;
    reg [15:0] cnt   = 0;
    reg [2:0]  bit_i = 0;
    reg [7:0]  shift = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tx    <= 1'b1;
            ready <= 1'b1;
            cnt   <= 0;
            bit_i <= 0;
        end else case (state)
            IDLE: begin
                tx    <= 1'b1;
                ready <= 1'b1;
                if (valid) begin
                    shift <= data;
                    ready <= 1'b0;
                    state <= START;
                    cnt   <= 0;
                end
            end
            START: begin
                tx <= 1'b0;
                if (cnt == DIV - 1) begin
                    cnt   <= 0;
                    state <= DATA;
                    bit_i <= 0;
                end else cnt <= cnt + 1'b1;
            end
            DATA: begin
                tx <= shift[0];
                if (cnt == DIV - 1) begin
                    cnt   <= 0;
                    shift <= shift >> 1;
                    if (bit_i == 3'd7) state <= STOP;
                    else bit_i <= bit_i + 1'b1;
                end else cnt <= cnt + 1'b1;
            end
            STOP: begin
                tx <= 1'b1;
                if (cnt == DIV - 1) begin
                    cnt   <= 0;
                    state <= IDLE;
                end else cnt <= cnt + 1'b1;
            end
            default: state <= IDLE;
        endcase
    end
endmodule
