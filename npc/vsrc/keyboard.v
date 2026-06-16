module keyboard (
    input  wire       clk,      // 系统时钟 (50MHz)
    input  wire       rst,      // 复位信号 (高有效)
    input  wire       ps2_clk,  // 键盘时钟
    input  wire       ps2_data, // 键盘数据

    output wire [6:0] hex0,     // 键码低位
    output wire [6:0] hex1,     // 键码高位
    output wire [6:0] hex2,     // ASCII码低位
    output wire [6:0] hex3,     // ASCII码高位
    output wire [6:0] hex4,     // 计数器低位 (BCD)
    output wire [6:0] hex5      // 计数器高位 (BCD)
);

    // ==========================================
    // 1. PS/2 协议接收器 (带跨时钟域同步)
    // ==========================================
    reg [2:0] ps2_clk_sync;
    always @(posedge clk) begin
        ps2_clk_sync <= {ps2_clk_sync[1:0], ps2_clk};
    end
    // 检测 ps2_clk 的下降沿
    wire sampling = (ps2_clk_sync[2:1] == 2'b10);

    reg [3:0] bit_cnt;
    reg [9:0] buffer;
    reg [7:0] rx_data;
    reg       rx_ready;

    always @(posedge clk) begin
        if (rst) begin
            bit_cnt <= 0;
            rx_ready <= 0;
        end else if (sampling) begin
            if (bit_cnt == 4'd10) begin
                rx_data <= buffer[8:1]; // 提取 8 位数据 (掐头去尾)
                rx_ready <= 1;
                bit_cnt <= 0;
            end else begin
                // LSB first 右移
                buffer <= {ps2_data, buffer[9:1]};
                bit_cnt <= bit_cnt + 1;
                rx_ready <= 0;
            end
        end else begin
            rx_ready <= 0;
        end
    end

    // ==========================================
    // 2. 键盘状态机与 BCD 计数器
    // ==========================================
    reg [7:0] current_code;
    reg       is_break;
    reg       show_en;
    
    // BCD 计数器
    reg [3:0] count_lo;
    reg [3:0] count_hi;

    always @(posedge clk) begin
        if (rst) begin
            current_code <= 8'h00;
            is_break <= 0;
            show_en <= 0;
            count_lo <= 0;
            count_hi <= 0;
        end else if (rx_ready) begin
            if (rx_data == 8'hF0) begin
                // 收到断码标识 F0，说明按键释放
                is_break <= 1;
            end else begin
                if (is_break) begin
                    // 断码后的扫描码：按键彻底释放
                    is_break <= 0;
                    show_en <= 0; // 松开时关闭数码管
                end else begin
                    // 通码（Make Code）：按键按下
                    // 为了防止长按导致连续触发，只有当新按键按下时才计数
                    if (!show_en || current_code != rx_data) begin
                        // BCD 加法逻辑
                        if (count_lo == 4'd9) begin
                            count_lo <= 0;
                            if (count_hi == 4'd9) count_hi <= 0; // 溢出清零
                            else count_hi <= count_hi + 1;
                        end else begin
                            count_lo <= count_lo + 1;
                        end
                    end
                    current_code <= rx_data;
                    show_en <= 1; // 点亮数码管
                end
            end
        end
    end

    // ==========================================
    // 3. ASCII ROM 查表 (仅包含字母和数字)
    // ==========================================
    reg [7:0] ascii_code;
    always @(*) begin
        case(current_code)
            // 字母 A-Z (大写)
            8'h1C: ascii_code = 8'h41; // A
            8'h32: ascii_code = 8'h42; // B
            8'h21: ascii_code = 8'h43; // C
            8'h23: ascii_code = 8'h44; // D
            8'h24: ascii_code = 8'h45; // E
            8'h2B: ascii_code = 8'h46; // F
            8'h34: ascii_code = 8'h47; // G
            8'h33: ascii_code = 8'h48; // H
            8'h43: ascii_code = 8'h49; // I
            8'h3B: ascii_code = 8'h4A; // J
            8'h42: ascii_code = 8'h4B; // K
            8'h4B: ascii_code = 8'h4C; // L
            8'h3A: ascii_code = 8'h4D; // M
            8'h31: ascii_code = 8'h4E; // N
            8'h44: ascii_code = 8'h4F; // O
            8'h4D: ascii_code = 8'h50; // P
            8'h15: ascii_code = 8'h51; // Q
            8'h2D: ascii_code = 8'h52; // R
            8'h1B: ascii_code = 8'h53; // S
            8'h2C: ascii_code = 8'h54; // T
            8'h3C: ascii_code = 8'h55; // U
            8'h2A: ascii_code = 8'h56; // V
            8'h1D: ascii_code = 8'h57; // W
            8'h22: ascii_code = 8'h58; // X
            8'h35: ascii_code = 8'h59; // Y
            8'h1A: ascii_code = 8'h5A; // Z
            // 数字 0-9
            8'h45: ascii_code = 8'h30; // 0
            8'h16: ascii_code = 8'h31; // 1
            8'h1E: ascii_code = 8'h32; // 2
            8'h26: ascii_code = 8'h33; // 3
            8'h25: ascii_code = 8'h34; // 4
            8'h2E: ascii_code = 8'h35; // 5
            8'h36: ascii_code = 8'h36; // 6
            8'h3D: ascii_code = 8'h37; // 7
            8'h3E: ascii_code = 8'h38; // 8
            8'h46: ascii_code = 8'h39; // 9
            default: ascii_code = 8'h00; // 未定义按键
        endcase
    end

    // ==========================================
    // 4. 七段数码管译码实例化
    // ==========================================
    // 键码 (受 show_en 控制，松开全灭)
    seg_decoder_en seg_code_l (.in(current_code[3:0]), .en(show_en), .out(hex0));
    seg_decoder_en seg_code_h (.in(current_code[7:4]), .en(show_en), .out(hex1));
    
    // ASCII码 (受 show_en 控制，松开全灭)
    seg_decoder_en seg_ascii_l (.in(ascii_code[3:0]), .en(show_en), .out(hex2));
    seg_decoder_en seg_ascii_h (.in(ascii_code[7:4]), .en(show_en), .out(hex3));

    // 按键次数 (永远显示)
    seg_decoder_en seg_count_l (.in(count_lo), .en(1'b1), .out(hex4));
    seg_decoder_en seg_count_h (.in(count_hi), .en(1'b1), .out(hex5));

endmodule

// 辅助模块：带使能端的共阳极数码管译码器
module seg_decoder_en (
    input  wire [3:0] in,
    input  wire       en,
    output reg  [6:0] out
);
    always @(*) begin
        if (!en) begin
            out = 7'b1111111; // 熄灭
        end else begin
            case (in)
                4'h0: out = 7'b1000000;
                4'h1: out = 7'b1111001;
                4'h2: out = 7'b0100100;
                4'h3: out = 7'b0110000;
                4'h4: out = 7'b0011001;
                4'h5: out = 7'b0010010;
                4'h6: out = 7'b0000010;
                4'h7: out = 7'b1111000;
                4'h8: out = 7'b0000000;
                4'h9: out = 7'b0010000;
                4'hA: out = 7'b0001000;
                4'hB: out = 7'b0000011;
                4'hC: out = 7'b1000110;
                4'hD: out = 7'b0100001;
                4'hE: out = 7'b0000110;
                4'hF: out = 7'b0001110;
                default: out = 7'b1111111;
            endcase
        end
    end
endmodule