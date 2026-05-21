/*module alu(
    input wire [31:0] src1,
    input wire [31:0] src2,
    input wire [3:0] alu_op,
    output reg [31:0] result
);
    always @(*) begin
        case (alu_op)
            4'b0000: result = src1 + src2; // ADD
            4'b0001: result = src1 - src2; // SUB
            4'b0010: result = src1 & src2; // AND
            4'b0011: result = src1 | src2; // OR
            4'b0100: result = src1 ^ src2; // XOR
            4'b0101: result = (src1 < src2) ? 32'h1 : 32'h0; // SLT
            default: result = 32'h0;
        endcase
    end
endmodule*/
module alu(
    input  wire [31:0] src1,
    input  wire [31:0] src2,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result
);
    // alu_op = { (is_sub || is_sra), funct3 }
    always @(*) begin
        case(alu_op)
            4'b0000: result = src1 + src2;                             // ADD
            4'b1000: result = src1 - src2;                             // SUB
            4'b0001: result = src1 << src2[4:0];                       // SLL
            4'b0010: result = ($signed(src1) < $signed(src2)) ? 1 : 0; // SLT
            4'b0011: result = (src1 < src2) ? 1 : 0;                   // SLTU
            4'b0100: result = src1 ^ src2;                             // XOR
            4'b0101: result = src1 >> src2[4:0];                       // SRL
            4'b1101: result = $signed(src1) >>> src2[4:0];             // SRA
            4'b0110: result = src1 | src2;                             // OR
            4'b0111: result = src1 & src2;                             // AND
            default: result = 32'b0;
        endcase
    end
endmodule