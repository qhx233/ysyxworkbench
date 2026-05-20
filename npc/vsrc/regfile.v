
module regfile(
    input wire       clk,
    input wire       rst,
    input wire       wen,
    input wire [4:0] waddr,
    input wire [31:0] wdata,
    input wire [4:0] raddr1,
    input wire [4:0] raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2,
    output wire [31:0] a0_val
);
    reg [31:0] rf [31:0];

    
    assign rdata1 = (raddr1 == 5'b0) ? 32'h0 : rf[raddr1];
    assign rdata2 = (raddr2 == 5'b0) ? 32'h0 : rf[raddr2];
    assign a0_val = rf[10]; // 监视 a0 寄存器的值

    always @(posedge clk) begin
        if (rst) begin
            integer i;
            for (i = 0; i < 32; i = i + 1) begin
                rf[i] <= 32'h0;
            end
        end else if (wen && waddr != 5'b0) begin
            rf[waddr] <= wdata;
        end
    end
endmodule