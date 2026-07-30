`timescale 1ns/1ps
module uart_rx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 1_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid   // pulses 1 cycle when a byte completes
);
    localparam [15:0] DIV = CLK_HZ / BAUD;
    localparam [1:0] IDLE = 0, START = 1, DATA = 2, STOP = 3;

    reg [1:0]  state = IDLE;
    reg [15:0] cnt   = 0;
    reg [2:0]  bit_i = 0;
    reg [7:0]  shift = 0;
    reg        meta = 1, sync = 1; // 2-FF synchronizer

    always @(posedge clk) begin
        meta <= rx;
        sync <= meta;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            valid <= 1'b0;
            cnt   <= 0;
            bit_i <= 0;
        end else begin
            valid <= 1'b0;
            case (state)
                IDLE: if (!sync) begin
                    state <= START;
                    cnt   <= 0;
                end
                START: if (cnt == DIV / 2) begin
                    if (!sync) begin
                        cnt   <= 0;
                        state <= DATA;
                        bit_i <= 0;
                    end else state <= IDLE; // false start
                end else cnt <= cnt + 1'b1;
                DATA: if (cnt == DIV - 1) begin
                    cnt   <= 0;
                    shift <= {sync, shift[7:1]};
                    if (bit_i == 3'd7) state <= STOP;
                    else bit_i <= bit_i + 1'b1;
                end else cnt <= cnt + 1'b1;
                STOP: if (cnt == DIV - 1) begin
                    data  <= shift;
                    valid <= 1'b1;
                    state <= IDLE;
                    cnt   <= 0;
                end else cnt <= cnt + 1'b1;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
