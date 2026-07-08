// APB wrapper for the OpenCores SPI master.
// 这个模块有两种访问入口:
// 1. CPU 访问 SPI master 的 MMIO 寄存器时, 本模块只是把 APB 请求转成 spi_top 的 Wishbone 请求.
// 2. CPU 访问 flash 映射窗口时, 本模块进入 XIP 状态机, 自动驱动 spi_top 读 flash.
// The XIP flash window drives the SPI master with an internal FSM.

`include "spi_defines.v"  // 引入 OpenCores SPI master 的寄存器编号和控制位定义.

module spi_top_apb #(
  parameter flash_addr_start = 32'h30000000, // XIP flash 映射空间起始地址.
  parameter flash_addr_end   = 32'h3fffffff, // XIP flash 映射空间结束地址; 当前比较使用 < end.
  parameter spi_ss_num       = 8             // SPI slave select 信号数量, ysyxSoC 中 flash=0, bitrev=7.
) (
  input         clock,      // APB/SPI wrapper 工作时钟.
  input         reset,      // 高有效复位.
  input  [31:0] in_paddr,   // APB 访问地址, 用来区分 SPI 寄存器空间和 flash XIP 空间.
  input         in_psel,    // APB select, 表示当前 APB slave 被选中.
  input         in_penable, // APB enable, 第二阶段拉高; 用于确认一次 APB 传输.
  input  [2:0]  in_pprot,   // APB protection 属性; 当前模块不使用.
  input         in_pwrite,  // APB 写使能: 1=写, 0=读.
  input  [31:0] in_pwdata,  // APB 写数据.
  input  [3:0]  in_pstrb,   // APB 字节写使能, 透传给 spi_top 的 byte select.
  output        in_pready,  // APB ready, 拉高表示本次 APB 访问完成.
  output [31:0] in_prdata,  // APB 读数据.
  output        in_pslverr, // APB 错误响应; XIP 写 flash 时用它报错.

  output                  spi_sck,     // SPI 时钟, 由 spi_top 产生.
  output [spi_ss_num-1:0] spi_ss,      // SPI 片选信号, 低有效输出到各个 slave.
  output                  spi_mosi,    // SPI master 输出到 slave 的串行数据.
  input                   spi_miso,    // SPI slave 返回给 master 的串行数据.
  output                  spi_irq_out  // SPI master 完成一次传输后的中断/完成信号.
);

  // spi_top 使用 Wishbone 风格的低地址译码, 地址单位是 byte.
  // spi_defines.v 中的寄存器编号是 word 编号, 左移 2 位后变成 byte offset.
  localparam [4:0] WB_TX0  = (`SPI_TX_0   << 2); // 发送寄存器 TX0 的 byte offset.
  localparam [4:0] WB_TX1  = (`SPI_TX_1   << 2); // 发送寄存器 TX1 的 byte offset.
  localparam [4:0] WB_RX0  = (`SPI_RX_0   << 2); // 接收寄存器 RX0 的 byte offset.
  localparam [4:0] WB_CTRL = (`SPI_CTRL   << 2); // 控制寄存器 CTRL 的 byte offset.
  localparam [4:0] WB_DIV  = (`SPI_DEVIDE << 2); // 分频寄存器 DIV 的 byte offset.
  localparam [4:0] WB_SS   = (`SPI_SS     << 2); // 片选寄存器 SS 的 byte offset.

  // XIP 读 flash 时写入 CTRL 的固定配置.
  // ASS: 自动片选; IE: 传输完成时产生 irq; TX_NEGEDGE: 下降沿更新 MOSI;
  // GO: 启动传输; 64: 总传输长度, 8-bit 命令 + 24-bit 地址 + 32-bit 返回数据.
  localparam [31:0] CTRL_XIP = (32'h1 << `SPI_CTRL_ASS) |
                               (32'h1 << `SPI_CTRL_IE)  |
                               (32'h1 << `SPI_CTRL_TX_NEGEDGE) |
                               (32'h1 << `SPI_CTRL_GO)  |
                               32'd64;

  // XIP 状态机的状态编码. 这些状态基本对应软件版 spi_flash_read() 的每一步寄存器写入.
  localparam [3:0] X_IDLE      = 4'd0; // 空闲, 等待 APB 访问 flash 地址空间.
  localparam [3:0] X_W_TX0     = 4'd1; // 写 TX0=0, 作为后 32-bit dummy 输出.
  localparam [3:0] X_W_TX1     = 4'd2; // 写 TX1={03h, addr}, 即 flash read 命令和 24-bit 地址.
  localparam [3:0] X_W_DIV     = 4'd3; // 写 DIV=0, 让仿真里的 SPI 时钟尽量快.
  localparam [3:0] X_W_SS      = 4'd4; // 写 SS=1, 选择 slave0, 即 flash.
  localparam [3:0] X_W_CTRL    = 4'd5; // 写 CTRL_XIP, 启动 64-bit SPI 传输.
  localparam [3:0] X_WAIT_IRQ  = 4'd6; // 等待 spi_top 传输完成.
  localparam [3:0] X_R_RX0     = 4'd7; // 读 RX0, 取回 flash 返回的 32-bit 数据.
  localparam [3:0] X_RESP      = 4'd8; // APB 回复阶段, 将 xip_rdata 返回给上游.

  wire unused_pprot = |in_pprot; // 避免未使用输入产生 lint 警告; 当前不根据 pprot 做权限检查.
  wire in_flash = (in_paddr >= flash_addr_start) && (in_paddr < flash_addr_end); // 判断是否访问 XIP flash 窗口.
  wire xip_active = (xip_state != X_IDLE); // 只要状态机不在空闲, spi_top 的输入就由 XIP 状态机接管.
  wire xip_start = in_psel && !in_penable && in_flash && !xip_active; // APB setup 阶段发现 flash 访问, 启动 XIP.
  wire normal_access = in_psel && !in_flash && !xip_active; // 非 flash 地址访问时, 作为普通 SPI 寄存器访问.

  reg [3:0] xip_state; // XIP 状态机当前状态.
  reg [31:0] xip_addr; // 本次 XIP 读取的 flash 内部 offset, 已按 4 字节对齐.
  reg [31:0] xip_rdata; // XIP 状态机最终返回给 APB 的读数据.
  reg xip_error; // XIP 错误标志; 当前主要用于拒绝 flash 写操作.

  reg        xip_wb_cyc; // XIP 状态机伪造给 spi_top 的 Wishbone cycle.
  reg        xip_wb_stb; // XIP 状态机伪造给 spi_top 的 Wishbone strobe.
  reg        xip_wb_we;  // XIP 状态机伪造给 spi_top 的写使能.
  reg [4:0]  xip_wb_adr; // XIP 状态机要访问的 spi_top 内部寄存器地址.
  reg [31:0] xip_wb_dat; // XIP 状态机要写入 spi_top 内部寄存器的数据.
  reg [3:0]  xip_wb_sel; // XIP 状态机的字节写使能, XIP 中固定全字写.

  wire        spi_ack;   // spi_top 对内部 Wishbone 访问的完成应答.
  wire        spi_err;   // spi_top 对内部 Wishbone 访问的错误应答.
  wire        spi_irq;   // spi_top 传输完成中断, XIP 用它判断 64-bit SPI 传输完成.
  wire [31:0] spi_rdata; // spi_top 内部寄存器读出的数据, 普通访问和 XIP 读 RX0 都会用到.
  wire [31:0] xip_word = {spi_rdata[7:0], spi_rdata[15:8], spi_rdata[23:16], spi_rdata[31:24]}; // 调整 SPI RX0 返回数据的字节序.

  // spi_top 只有一套 Wishbone 输入. XIP 进行中时由 XIP 状态机驱动;
  // 否则由 APB 普通访问路径驱动, 让软件可以直接操作 SPI master 寄存器.
  wire        wb_cyc = xip_active ? xip_wb_cyc : (normal_access && in_penable); // Wishbone cycle 有效.
  wire        wb_stb = xip_active ? xip_wb_stb : normal_access;                 // Wishbone strobe 有效.
  wire        wb_we  = xip_active ? xip_wb_we  : in_pwrite;                     // Wishbone 写使能.
  wire [4:0]  wb_adr = xip_active ? xip_wb_adr : in_paddr[4:0];                 // Wishbone 寄存器地址.
  wire [31:0] wb_dat = xip_active ? xip_wb_dat : in_pwdata;                     // Wishbone 写数据.
  wire [3:0]  wb_sel = xip_active ? xip_wb_sel : in_pstrb;                      // Wishbone 字节使能.

  assign spi_irq_out = spi_irq; // 将 spi_top 的完成中断继续暴露给 SoC 顶层.

  // APB 回复多路选择:
  // flash XIP 访问只有进入 X_RESP 后才 ready; 普通 SPI 寄存器访问直接使用 spi_top 的 ack.
  assign in_pready = in_flash ? (xip_state == X_RESP && in_penable) : spi_ack;
  assign in_prdata = in_flash ? xip_rdata : spi_rdata; // flash 访问返回 XIP 数据, 普通访问返回 spi_top 寄存器数据.
  assign in_pslverr = in_flash ? xip_error : spi_err;  // flash 写操作会产生 xip_error; 普通访问透传 spi_top 错误.

  always @(*) begin
    // 默认不访问 spi_top, 避免组合逻辑产生锁存器.
    xip_wb_cyc = 1'b0;    // 默认不发起 Wishbone cycle.
    xip_wb_stb = 1'b0;    // 默认不发起 Wishbone strobe.
    xip_wb_we  = 1'b0;    // 默认是读访问.
    xip_wb_adr = 5'b0;    // 默认地址清零.
    xip_wb_dat = 32'b0;   // 默认写数据清零.
    xip_wb_sel = 4'b1111; // XIP 总是按 32-bit 寄存器访问.

    case (xip_state)
      X_W_TX0: begin
        xip_wb_cyc = 1'b1;  // 发起一次写 TX0 的 Wishbone 访问.
        xip_wb_stb = 1'b1;  // strobe 拉高, 表示访问有效.
        xip_wb_we  = 1'b1;  // 写 spi_top 寄存器.
        xip_wb_adr = WB_TX0; // 选择 TX0 寄存器.
        xip_wb_dat = 32'b0; // 后 32-bit SPI 传输发送 dummy 0, 用于换回 flash 数据.
      end
      X_W_TX1: begin
        xip_wb_cyc = 1'b1;  // 发起一次写 TX1 的 Wishbone 访问.
        xip_wb_stb = 1'b1;  // strobe 拉高, 表示访问有效.
        xip_wb_we  = 1'b1;  // 写 spi_top 寄存器.
        xip_wb_adr = WB_TX1; // 选择 TX1 寄存器.
        xip_wb_dat = {8'h03, xip_addr[23:0]}; // 发送 03h 普通读命令和 24-bit flash 地址.
      end
      X_W_DIV: begin
        xip_wb_cyc = 1'b1;  // 发起一次写 DIV 的 Wishbone 访问.
        xip_wb_stb = 1'b1;  // strobe 拉高, 表示访问有效.
        xip_wb_we  = 1'b1;  // 写 spi_top 寄存器.
        xip_wb_adr = WB_DIV; // 选择分频寄存器.
        xip_wb_dat = 32'b0; // 分频为 0, 在仿真中尽量提高 SPI 传输速度.
      end
      X_W_SS: begin
        xip_wb_cyc = 1'b1;  // 发起一次写 SS 的 Wishbone 访问.
        xip_wb_stb = 1'b1;  // strobe 拉高, 表示访问有效.
        xip_wb_we  = 1'b1;  // 写 spi_top 寄存器.
        xip_wb_adr = WB_SS; // 选择 slave select 寄存器.
        xip_wb_dat = 32'h1; // 选择 slave0, 即 ysyxSoC 中的 flash 颗粒.
      end
      X_W_CTRL: begin
        xip_wb_cyc = 1'b1;  // 发起一次写 CTRL 的 Wishbone 访问.
        xip_wb_stb = 1'b1;  // strobe 拉高, 表示访问有效.
        xip_wb_we  = 1'b1;  // 写 spi_top 寄存器.
        xip_wb_adr = WB_CTRL; // 选择控制寄存器.
        xip_wb_dat = CTRL_XIP; // 写入 XIP 固定控制字, 启动 64-bit SPI flash 读传输.
      end
      X_R_RX0: begin
        xip_wb_cyc = 1'b1;  // 发起一次读 RX0 的 Wishbone 访问.
        xip_wb_stb = 1'b1;  // strobe 拉高, 表示访问有效.
        xip_wb_we  = 1'b0;  // 读 spi_top 寄存器.
        xip_wb_adr = WB_RX0; // 选择 RX0, 里面保存 flash 返回的 32-bit 数据.
      end
      default: begin end // 其它状态不访问 spi_top.
    endcase
  end

  always @(posedge clock) begin
    if (reset) begin
      xip_state <= X_IDLE; // 复位后 XIP 状态机回到空闲.
      xip_addr <= 32'b0;   // 清空待访问 flash 地址.
      xip_rdata <= 32'b0;  // 清空返回数据寄存器.
      xip_error <= 1'b0;   // 清空错误标志.
    end else begin
      case (xip_state)
        X_IDLE: begin
          if (xip_start) begin
            xip_addr <= {8'b0, in_paddr[23:2], 2'b0}; // 取 flash 内部 24-bit offset, 并按 4 字节对齐读 word.
            xip_rdata <= 32'b0; // 新一次 XIP 访问开始时先清空旧数据.
            xip_error <= in_pwrite; // 当前 XIP 只支持读; 如果上游写 flash, 记录错误.
            xip_state <= in_pwrite ? X_RESP : X_W_TX0; // 写 flash 直接回复错误, 读 flash 进入自动读流程.
          end
        end
        X_W_TX0:    if (spi_ack) xip_state <= X_W_TX1;    // TX0 写完成后, 继续写 TX1.
        X_W_TX1:    if (spi_ack) xip_state <= X_W_DIV;    // TX1 写完成后, 继续写 DIV.
        X_W_DIV:    if (spi_ack) xip_state <= X_W_SS;     // DIV 写完成后, 继续写 SS.
        X_W_SS:     if (spi_ack) xip_state <= X_W_CTRL;   // SS 写完成后, 继续写 CTRL 启动传输.
        X_W_CTRL:   if (spi_ack) xip_state <= X_WAIT_IRQ; // CTRL 写完成后, 等待 SPI 串行传输完成.
        X_WAIT_IRQ: if (spi_irq) xip_state <= X_R_RX0;    // spi_top 报告完成后, 读取 RX0.
        X_R_RX0: begin
          if (spi_ack) begin
            xip_rdata <= xip_word; // 锁存并调整字节序后的 flash 返回数据.
            xip_state <= X_RESP;   // 进入 APB 回复状态.
          end
        end
        X_RESP: begin
          if (in_psel && in_penable) xip_state <= X_IDLE; // APB master 接收回复后, XIP 状态机回到空闲.
        end
        default: xip_state <= X_IDLE; // 异常状态兜底回到空闲.
      endcase
    end
  end

  spi_top u0_spi_top (
    .wb_clk_i(clock),     // spi_top 使用同一个时钟.
    .wb_rst_i(reset),     // spi_top 使用同一个复位.
    .wb_adr_i(wb_adr),    // 经过 normal/XIP 多路选择后的 Wishbone 地址.
    .wb_dat_i(wb_dat),    // 经过 normal/XIP 多路选择后的 Wishbone 写数据.
    .wb_dat_o(spi_rdata), // spi_top 寄存器读数据.
    .wb_sel_i(wb_sel),    // 经过 normal/XIP 多路选择后的字节使能.
    .wb_we_i (wb_we),     // 经过 normal/XIP 多路选择后的写使能.
    .wb_stb_i(wb_stb),    // 经过 normal/XIP 多路选择后的 strobe.
    .wb_cyc_i(wb_cyc),    // 经过 normal/XIP 多路选择后的 cycle.
    .wb_ack_o(spi_ack),   // spi_top 完成一次寄存器访问.
    .wb_err_o(spi_err),   // spi_top 报告寄存器访问错误; 当前一般为 0.
    .wb_int_o(spi_irq),   // spi_top 完成 SPI 串行传输后产生中断/完成信号.

    .ss_pad_o(spi_ss),    // 输出到外部 SPI slave 的片选信号.
    .sclk_pad_o(spi_sck), // 输出到外部 SPI slave 的 SPI 时钟.
    .mosi_pad_o(spi_mosi), // 输出到外部 SPI slave 的 MOSI.
    .miso_pad_i(spi_miso) // 从外部 SPI slave 输入的 MISO.
  );

endmodule // spi_top_apb
