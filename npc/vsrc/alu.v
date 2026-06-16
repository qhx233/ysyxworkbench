module alu (
    input  wire [3:0] A,        // 操作数 A (带符号补码)
    input  wire [3:0] B,        // 操作数 B (带符号补码)
    input  wire [2:0] op,       // 操作码 op
    
    output reg  [3:0] out,      // 4位运算结果
    output reg        Zero,     // 零标志位
    output reg        Overflow, // 溢出标志位
    output reg        Carry     // 进位标志位
);

    // 扩展到 5 位进行加减法运算，方便提取最高位的进位 (Carry)
    wire [4:0] ext_A = {1'b0, A};
    wire [4:0] ext_B = {1'b0, B};
    
    // 预先计算加法和减法的结果
    wire [4:0] add_res = ext_A + ext_B;
    // 补码减法：A - B 等价于 A + (~B) + 1
    wire [4:0] sub_res = ext_A + (~ext_B) + 5'b00001; 

    always @(*) begin
        // 1. 初始化默认值，防止综合工具生成锁存器 (Latch)
        out = 4'b0000;
        Zero = 1'b0;
        Overflow = 1'b0;
        Carry = 1'b0;

        // 2. 根据操作码 op 选择对应的功能
        case (op)
            3'b000: begin // 加法 A + B
                out = add_res[3:0];
                Carry = add_res[4];
                // 溢出条件：同号相加得异号
                Overflow = (A[3] == B[3]) && (out[3] != A[3]);
                Zero = (out == 4'b0000);
            end
            3'b001: begin // 减法 A - B
                out = sub_res[3:0];
                Carry = sub_res[4]; 
                // 溢出条件：异号相减得同号（结果与减数同号，与被减数异号）
                Overflow = (A[3] != B[3]) && (out[3] != A[3]);
                Zero = (out == 4'b0000);
            end
            3'b010: begin // 取反 Not A
                out = ~A;
            end
            3'b011: begin // 与 A and B
                out = A & B;
            end
            3'b100: begin // 或 A or B
                out = A | B;
            end
            3'b101: begin // 异或 A xor B
                out = A ^ B;
            end
            3'b110: begin // 比较大小 If A < B (带符号)
                // $signed() 强制按照带符号补码进行比较
                out = ($signed(A) < $signed(B)) ? 4'b0001 : 4'b0000;
            end
            3'b111: begin // 判断相等 If A == B
                out = (A == B) ? 4'b0001 : 4'b0000;
            end
            default: begin
                out = 4'b0000;
            end
        endcase
    end

endmodule