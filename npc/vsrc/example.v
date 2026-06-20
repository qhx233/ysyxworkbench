/*module example(
    input a,
    input b,
    output f
);
    assign f = a ^ b;
endmodule*/

/*module example(
    input clk,
    input rst,
    output reg [7:0] led
);
    reg [31:0] count;
    always @(posedge clk) begin
        if(rst) begin
            count <= 32'd0;
            led <= 8'b00000001;
        end else begin
            if(count == 32'd50000000) begin
                count <= 32'd0;
                led <= {led[6:0], led[7]};
            end else begin
                count <= count + 1;
            end
        end
        
    end
endmodule*/
///////////////////////////////////////111111111111///////////////////////////////////////

//////////////////////////////////////22222222222222222///////////////////////////////////////

module example (
    input  wire       en,      // 使能端 (对应拨码开关 SW8)
    input  wire [7:0] sw,      // 8位二进制输入 (对应拨码开关 SW7 ~ SW0)
    
    output reg  [2:0] led,     // 3位编码结果 (对应发光二极管 LED2 ~ LED0)
    output wire       valid,   // 输入有效指示位 (对应发光二极管 LED4)
    output reg  [6:0] hex      // 七段数码管输出 (对应数码管 HEX0)
);

    // ----------------------------------------------------
    // 第一部分：高位优先编码器与有效指示位逻辑
    // ----------------------------------------------------
    
    // 指示位逻辑：只要 sw 中有任意一位是 1，valid 就为 1。
    // 使用按位或归约操作符 `|` 实现。使能端关闭时，强制归零。
    assign valid = en ? (|sw) : 1'b0;

    // 优先编码逻辑：从高位到低位依次判断
    always @(*) begin
        if (!en) begin
            led = 3'b000;
        end else begin
            if      (sw[7]) led = 3'd7; // 111
            else if (sw[6]) led = 3'd6; // 110
            else if (sw[5]) led = 3'd5; // 101
            else if (sw[4]) led = 3'd4; // 100
            else if (sw[3]) led = 3'd3; // 011
            else if (sw[2]) led = 3'd2; // 010
            else if (sw[1]) led = 3'd1; // 001
            else if (sw[0]) led = 3'd0; // 000
            else            led = 3'd0; // 全0情况
        end
    end

    // ----------------------------------------------------
    // 第二部分：七段数码管译码器 (共阳极，低电平点亮)
    // 数据位对应关系： {g, f, e, d, c, b, a}
    // ----------------------------------------------------
    always @(*) begin
        // 如果使能端未打开，或者没有任何有效输入，数码管全灭
        if (!en || !valid) begin
            hex = 7'b1111111; 
        end else begin
            case (led)
                //               gfedcba
                3'd0: hex = 7'b1000000; // 显示 0
                3'd1: hex = 7'b1111001; // 显示 1
                3'd2: hex = 7'b0100100; // 显示 2
                3'd3: hex = 7'b0110000; // 显示 3 (题目示例)
                3'd4: hex = 7'b0011001; // 显示 4
                3'd5: hex = 7'b0010010; // 显示 5
                3'd6: hex = 7'b0000010; // 显示 6
                3'd7: hex = 7'b1111000; // 显示 7
                default: hex = 7'b1111111;
            endcase
        end
    end

endmodule