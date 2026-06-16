module lfsr (
    input  wire       clk,   // 系统时钟 (由 C++ 驱动)
    input  wire       rst,   // 复位开关 (恢复到初始种子)
    input  wire       btn,   // 按键输入 (按一次移位一次)
    
    output reg  [7:0] out,   // 随机数输出 (绑定到 LED 方便观察)
    output wire [6:0] hex1,  // 高 4 位十六进制数码管
    output wire [6:0] hex0   // 低 4 位十六进制数码管
);

    // ==========================================
    // 1. 按键上升沿检测电路 (Edge Detection)
    // ==========================================
    reg btn_d1, btn_d2;
    always @(posedge clk) begin
        btn_d1 <= btn;
        btn_d2 <= btn_d1;
    end
    // 当上一个周期是 1，上上个周期是 0 时，说明产生了一个上升沿
    wire btn_posedge = btn_d1 & ~btn_d2;

    // ==========================================
    // 2. LFSR 核心逻辑
    // ==========================================
    // 反馈多项式：b7 = b4 ^ b3 ^ b2 ^ b0
    wire feedback = out[4] ^ out[3] ^ out[2] ^ out[0];

    always @(posedge clk) begin
        if (rst) begin
            // 复位时恢复初始状态 (种子不能为全 0)
            out <= 8'b0000_0001; 
        end else if (btn_posedge) begin
            // 只有在按下按钮的瞬间才进行移位
            if (out == 8'b0000_0000) begin
                // 特殊处理：如果意外陷入全 0 状态，强制跳出
                out <= 8'b0000_0001;
            end else begin
                // 右移一位，最高位补入 feedback
                out <= {feedback, out[7:1]};
            end
        end
    end

    // ==========================================
    // 3. 七段数码管译码器实例化
    // ==========================================
    seg_decoder seg_high (
        .in(out[7:4]),
        .hex_out(hex1)
    );

    seg_decoder seg_low (
        .in(out[3:0]),
        .hex_out(hex0)
    );

endmodule


// ==========================================
// 辅助模块：十六进制数码管译码器 (共阳极)
// ==========================================
module seg_decoder (
    input  wire [3:0] in,
    output reg  [6:0] hex_out
);
    always @(*) begin
        case (in)
            4'h0: hex_out = 7'b1000000;
            4'h1: hex_out = 7'b1111001;
            4'h2: hex_out = 7'b0100100;
            4'h3: hex_out = 7'b0110000;
            4'h4: hex_out = 7'b0011001;
            4'h5: hex_out = 7'b0010010;
            4'h6: hex_out = 7'b0000010;
            4'h7: hex_out = 7'b1111000;
            4'h8: hex_out = 7'b0000000;
            4'h9: hex_out = 7'b0010000;
            4'ha: hex_out = 7'b0001000; // A
            4'hb: hex_out = 7'b0000011; // b
            4'hc: hex_out = 7'b1000110; // C
            4'hd: hex_out = 7'b0100001; // d
            4'he: hex_out = 7'b0000110; // E
            4'hf: hex_out = 7'b0001110; // F
            default: hex_out = 7'b1111111;
        endcase
    end
endmodule