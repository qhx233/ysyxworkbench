module vga_top (
    input  wire       clk,        // 【修改点】：在仿真中，直接将 clk 视为 25MHz 的像素时钟
    input  wire       rst,        
    
    output wire [7:0] VGA_R,
    output wire [7:0] VGA_G,
    output wire [7:0] VGA_B,
    output wire       VGA_HSYNC,
    output wire       VGA_VSYNC,
    output wire       VGA_BLANK_N
);

    // 【修改点】：彻底删除了 vga_clk 二分频逻辑

    // 实例化 ROM 显存并读取数据
    reg [11:0] vram [0:307199];
    
    initial begin
        $readmemh("image.txt", vram);
    end

    wire [9:0] h_addr;
    wire [9:0] v_addr;
    
    // 显式位宽扩展
    wire [18:0] rom_addr = ({9'b0, v_addr} * 19'd640) + {9'b0, h_addr};
    
    wire [11:0] pixel_12bit = (h_addr < 640 && v_addr < 480) ? vram[rom_addr] : 12'h000;

    wire [23:0] vga_data = {pixel_12bit[11:8], 4'b0000, 
                            pixel_12bit[7:4],  4'b0000, 
                            pixel_12bit[3:0],  4'b0000};

    wire valid;
    
    // 【修改点】：直接将顶层 clk 连接到 pclk
    vga_ctrl u_vga_ctrl (
        .pclk     (clk),      
        .reset    (rst),
        .vga_data (vga_data),
        .h_addr   (h_addr),
        .v_addr   (v_addr),
        .hsync    (VGA_HSYNC),
        .vsync    (VGA_VSYNC),
        .valid    (valid),
        .vga_r    (VGA_R),
        .vga_g    (VGA_G),
        .vga_b    (VGA_B)
    );

    assign VGA_BLANK_N = valid;

endmodule

// ==========================================
// 附件：VGA 时序控制器 (实验指导书提供)
// ==========================================
module vga_ctrl(
    input           pclk,     
    input           reset,    
    input  [23:0]   vga_data, 
    output [9:0]    h_addr,   
    output [9:0]    v_addr,
    output          hsync,    
    output          vsync,
    output          valid,    
    output [7:0]    vga_r,    
    output [7:0]    vga_g,
    output [7:0]    vga_b
);
    parameter h_frontporch = 96;
    parameter h_active = 144;
    parameter h_backporch = 784;
    parameter h_total = 800;
    parameter v_frontporch = 2;
    parameter v_active = 35;
    parameter v_backporch = 515;
    parameter v_total = 525;

    reg [9:0] x_cnt;
    reg [9:0] y_cnt;
    wire h_valid;
    wire v_valid;

    always @(posedge reset or posedge pclk) begin
        if (reset == 1'b1)
            x_cnt <= 1;
        else begin
            if (x_cnt == h_total) x_cnt <= 1;
            else x_cnt <= x_cnt + 10'd1;
        end
    end

    always @(posedge pclk) begin
        if (reset == 1'b1)
            y_cnt <= 1;
        else begin
            if (y_cnt == v_total & x_cnt == h_total) y_cnt <= 1;
            else if (x_cnt == h_total) y_cnt <= y_cnt + 10'd1;
        end
    end

    assign hsync = (x_cnt > h_frontporch);
    assign vsync = (y_cnt > v_frontporch);
    assign h_valid = (x_cnt > h_active) & (x_cnt <= h_backporch);
    assign v_valid = (y_cnt > v_active) & (y_cnt <= v_backporch);
    assign valid = h_valid & v_valid;
    assign h_addr = h_valid ? (x_cnt - 10'd145) : {10{1'b0}};
    assign v_addr = v_valid ? (y_cnt - 10'd36) : {10{1'b0}};
    assign vga_r = vga_data[23:16];
    assign vga_g = vga_data[15:8];
    assign vga_b = vga_data[7:0];
endmodule