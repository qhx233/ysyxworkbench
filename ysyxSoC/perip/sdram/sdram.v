// SDRAM simulation model used by ysyxSoC.
// 外层模块把 4 个 16-bit SDRAM 颗粒拼成一个 32-bit、双片选(rank)的 SDRAM 设备.
module sdram(
  input        clk, // SDRAM 时钟, 控制器在这个时钟边沿发命令/采样数据.
  input        cke, // clock enable, 为 0 时忽略控制命令.
  input [ 1:0] cs,  // chip select, 低电平有效; cs[0]/cs[1] 分别选择两个 rank.
  input        ras, // row address strobe, 与 cas/we/cs 一起编码 SDRAM 命令.
  input        cas, // column address strobe, 与 ras/we/cs 一起编码 SDRAM 命令.
  input        we,  // write enable, 与 ras/cas/cs 一起编码 SDRAM 命令.
  input [12:0] a,   // 地址引脚; ACTIVE 时表示 row, READ/WRITE 时表示 column, LOAD_MODE 时表示模式值.
  input [ 1:0] ba,  // bank address, 选择 4 个 bank 中的一个.
  input [ 3:0] dqm, // data mask, 每 bit 屏蔽一个 byte lane; 高有效屏蔽.
  inout [31:0] dq   // 32-bit 双向数据总线.
);

  sdram_x16 u_sdram_r0_lo (
    .clk(clk),       // rank0 低 16-bit 颗粒与控制器共用时钟.
    .cke(cke),       // 透传 clock enable.
    .cs(cs[0]),      // cs[0] 选中 rank0.
    .ras(ras),       // 透传命令位 RAS.
    .cas(cas),       // 透传命令位 CAS.
    .we(we),         // 透传命令位 WE.
    .a(a),           // 透传地址引脚.
    .ba(ba),         // 透传 bank 地址.
    .dqm(dqm[1:0]),  // 低 16-bit 对应 byte0/byte1 的 mask.
    .dq(dq[15:0])    // 连接到 32-bit 数据总线低半部分.
  );

  sdram_x16 u_sdram_r0_hi (
    .clk(clk),       // rank0 高 16-bit 颗粒与控制器共用时钟.
    .cke(cke),       // 透传 clock enable.
    .cs(cs[0]),      // cs[0] 选中 rank0.
    .ras(ras),       // 透传命令位 RAS.
    .cas(cas),       // 透传命令位 CAS.
    .we(we),         // 透传命令位 WE.
    .a(a),           // 透传地址引脚.
    .ba(ba),         // 透传 bank 地址.
    .dqm(dqm[3:2]),  // 高 16-bit 对应 byte2/byte3 的 mask.
    .dq(dq[31:16])   // 连接到 32-bit 数据总线高半部分.
  );

  sdram_x16 u_sdram_r1_lo (
    .clk(clk),       // rank1 低 16-bit 颗粒与控制器共用时钟.
    .cke(cke),       // 透传 clock enable.
    .cs(cs[1]),      // cs[1] 选中 rank1.
    .ras(ras),       // 透传命令位 RAS.
    .cas(cas),       // 透传命令位 CAS.
    .we(we),         // 透传命令位 WE.
    .a(a),           // 透传地址引脚.
    .ba(ba),         // 透传 bank 地址.
    .dqm(dqm[1:0]),  // 低 16-bit 对应 byte0/byte1 的 mask.
    .dq(dq[15:0])    // 与 rank0 低半部分共用总线; 未选中时为高阻.
  );

  sdram_x16 u_sdram_r1_hi (
    .clk(clk),       // rank1 高 16-bit 颗粒与控制器共用时钟.
    .cke(cke),       // 透传 clock enable.
    .cs(cs[1]),      // cs[1] 选中 rank1.
    .ras(ras),       // 透传命令位 RAS.
    .cas(cas),       // 透传命令位 CAS.
    .we(we),         // 透传命令位 WE.
    .a(a),           // 透传地址引脚.
    .ba(ba),         // 透传 bank 地址.
    .dqm(dqm[3:2]),  // 高 16-bit 对应 byte2/byte3 的 mask.
    .dq(dq[31:16])   // 与 rank0 高半部分共用总线; 未选中时为高阻.
  );

endmodule // sdram

// A single 16-bit SDRAM chip model.
// 它只实现当前 SDRAM 控制器会用到的命令, 并忽略真实颗粒中的刷新/预充电电气细节.
module sdram_x16(
  input        clk, // SDRAM 时钟.
  input        cke, // clock enable; 为 0 时不处理新命令.
  input        cs,  // chip select, 低有效; 与 ras/cas/we 一起组成命令编码.
  input        ras, // row address strobe.
  input        cas, // column address strobe.
  input        we,  // write enable.
  input [12:0] a,   // 13-bit 地址引脚.
  input [ 1:0] ba,  // 2-bit bank 地址, 共 4 个 bank.
  input [ 1:0] dqm, // 16-bit 颗粒有 2 个 byte mask, 高有效屏蔽对应 byte.
  inout [15:0] dq   // 16-bit 双向数据总线.
);

  localparam CMD_LOAD_MODE = 4'b0000; // LOAD MODE REGISTER: 设置 burst length 和 CAS latency.
  localparam CMD_AUTO_REF  = 4'b0001; // AUTO REFRESH: 仿真中不建模刷新, 当作无数据访问命令.
  localparam CMD_PRECHG    = 4'b0010; // PRECHARGE: 仿真中不建模预充电, 只结束可能的写 burst.
  localparam CMD_ACTIVE    = 4'b0011; // ACTIVE: 打开某个 bank 的某一行.
  localparam CMD_WRITE     = 4'b0100; // WRITE: 向 active row 的指定 column 写数据.
  localparam CMD_READ      = 4'b0101; // READ: 从 active row 的指定 column 读数据.

  localparam COL_W   = 9;          // column 位宽, 与控制器参数 SDRAM_COL_W=9 对应.
  localparam ROW_W   = 13;         // row 位宽, MT48LC16M16A2 风格的 13-bit row.
  localparam BANKS   = 4;          // 每个 x16 颗粒有 4 个 bank.
  localparam MEM_AW  = 24;         // 模型内部 word 地址位宽: row + bank + col = 13 + 2 + 9.
  localparam MEM_SZ  = 1 << MEM_AW; // 每个数组元素是 16-bit, 共 2^24 个 halfword.

  reg [15:0] mem [0:MEM_SZ-1]; // 行为模型的存储阵列; 不模拟真实 DRAM 物理组织和刷新.
  reg [ROW_W-1:0] active_row [0:BANKS-1]; // 记录每个 bank 当前 ACTIVE 打开的 row.
  reg [2:0] burst_len; // Mode register 中解析出的 burst length; 0 在这里代表较长/不常用模式.
  reg [1:0] cas_latency; // Mode register 中解析出的 CAS latency, 当前支持 2 或 3.

  reg [15:0] dq_out; // 本颗粒要驱动到 dq 总线上的读数据.
  reg        dq_oe;  // dq output enable; 1 时驱动 dq, 0 时释放为高阻.
  assign dq = dq_oe ? dq_out : 16'bz; // SDRAM 读时由颗粒驱动 dq, 写/空闲时释放总线.

  wire [3:0] cmd = {cs, ras, cas, we}; // 用 cs/ras/cas/we 的组合识别 SDRAM 命令.
  wire [15:0] dq_in = dq; // 写命令时从双向 dq 总线上采样输入数据.

  reg [MEM_AW-1:0] read_addr; // 等待返回的读地址.
  reg [1:0]        read_delay; // CAS latency 造成的读延迟计数.
  reg              read_pending; // 已收到 READ 命令, 正在等待 CAS latency.
  reg              read_second_valid; // 用于简单支持 burst 的第二个 halfword 输出.
  reg              read_drive_valid; // 下一拍 dq_oe 是否拉高; 让数据保持到控制器采样点.
  reg [MEM_AW-1:0] write_next_addr; // burst write 的下一个 halfword 地址.
  reg              write_burst_valid; // 下一拍是否继续写 burst 的第二个 halfword.

  integer i;
  initial begin
    burst_len = 3'd2; // 默认 burst length 为 2, 匹配常见初始化后的访问方式.
    cas_latency = 2'd2; // 默认 CAS latency 为 2.
    dq_out = 16'h0; // 默认读输出为 0.
    dq_oe = 1'b0; // 初始不驱动 dq, 避免和控制器写数据冲突.
    write_next_addr = {MEM_AW{1'b0}}; // 清空 burst 写地址.
    write_burst_valid = 1'b0; // 初始没有待完成的 burst 写.
    read_addr = {MEM_AW{1'b0}}; // 清空读地址.
    read_delay = 2'b0; // 清空读延迟计数.
    read_pending = 1'b0; // 初始没有待返回的读.
    read_second_valid = 1'b0; // 初始没有第二拍 burst 读.
    read_drive_valid = 1'b0; // 初始下一拍不驱动 dq.
    for (i = 0; i < BANKS; i = i + 1) begin
      active_row[i] = {ROW_W{1'b0}}; // 每个 bank 的 active row 初始为 0.
    end
  end

  // 将 SDRAM 的 bank/row/column 三元组映射成行为模型数组下标.
  function [MEM_AW-1:0] make_addr;
    input [1:0] bank;          // bank 地址.
    input [ROW_W-1:0] row;     // 当前 ACTIVE 的 row.
    input [COL_W-1:0] col;     // READ/WRITE 命令给出的 column.
    begin
      make_addr = {row, bank, col}; // 简化模型中直接拼接成线性 halfword 地址.
    end
  endfunction

  // 解码 Mode Register 中的 burst length 字段.
  function [2:0] decode_burst_len;
    input [2:0] mode_bl; // Mode Register a[2:0].
    begin
      case (mode_bl)
        3'b000: decode_burst_len = 3'd1; // burst length = 1.
        3'b001: decode_burst_len = 3'd2; // burst length = 2.
        3'b010: decode_burst_len = 3'd4; // burst length = 4; 当前模型只显式用到是否等于 1.
        3'b011: decode_burst_len = 3'd0; // 代表更长 burst, 当前模型不完整展开.
        default: decode_burst_len = 3'd2; // 不支持的编码保守按 BL=2 处理.
      endcase
    end
  endfunction

  // 写一个 16-bit halfword, 并根据 dqm 做 byte mask.
  task write_half;
    input [MEM_AW-1:0] addr; // 要写入的内部 halfword 地址.
    input [15:0] data;       // 从 dq 采到的 16-bit 写数据.
    input [1:0] mask;        // dqm mask, 高有效; mask bit 为 1 表示不写对应 byte.
    begin
      if (!mask[0]) mem[addr][7:0]  = data[7:0];  // dqm[0]=0 时写低 byte.
      if (!mask[1]) mem[addr][15:8] = data[15:8]; // dqm[1]=0 时写高 byte.
    end
  endtask

  always @(posedge clk) begin
    dq_oe <= read_drive_valid; // 上一拍决定本拍是否驱动 dq, 让读数据有效窗口覆盖控制器采样点.
    read_drive_valid <= 1'b0;  // 默认下一拍不继续驱动, 只有 READ 数据准备好时重新置位.

    if (read_pending) begin
      if (read_delay != 2'b0) begin
        read_delay <= read_delay - 1'b1; // CAS latency 还没到, 继续等待.
      end else begin
        dq_out <= mem[read_addr]; // 延迟到期, 把第一个 halfword 放到输出寄存器.
        read_addr <= read_addr + 1'b1; // burst 读的下一个地址.
        read_pending <= 1'b0; // 第一个读数据已经准备好.
        read_drive_valid <= 1'b1; // 下一拍驱动 dq 输出这个读数据.
        read_second_valid <= (burst_len != 3'd1); // 如果 BL 不是 1, 再输出第二个连续 halfword.
      end
    end else if (read_second_valid) begin
      dq_out <= mem[read_addr]; // 简化支持 burst 的第二个 halfword.
      read_drive_valid <= 1'b1; // 下一拍继续驱动 dq.
      read_second_valid <= 1'b0; // 第二拍输出后结束这次 burst.
    end

    if (cke) begin
      if (write_burst_valid) begin
        write_half(write_next_addr, dq_in, dqm); // WRITE 后的下一拍继续写 burst 的第二个 halfword.
        write_next_addr <= write_next_addr + 1'b1; // 更新 burst 写地址.
        write_burst_valid <= 1'b0; // 当前模型只补一拍 burst 写.
      end

      case (cmd)
        CMD_LOAD_MODE: begin
          burst_len <= decode_burst_len(a[2:0]); // Mode Register a[2:0] 设置 burst length.
          cas_latency <= a[6:4] == 3'd3 ? 2'd3 : 2'd2; // Mode Register a[6:4] 设置 CAS latency.
        end

        CMD_AUTO_REF,
        CMD_PRECHG: begin
          write_burst_valid <= 1'b0; // 刷新/预充电在仿真中不改存储内容, 只终止待写 burst.
        end

        CMD_ACTIVE: begin
          active_row[ba] <= a; // 打开 bank ba 的 row a, 后续 READ/WRITE 使用这个 row.
        end

        CMD_WRITE: begin
          write_half(make_addr(ba, active_row[ba], a[COL_W-1:0]), dq_in, dqm); // 立即写当前 column.
          write_next_addr <= make_addr(ba, active_row[ba], a[COL_W-1:0]) + 1'b1; // 记录 burst 写下一列.
          write_burst_valid <= (burst_len != 3'd1); // BL 不为 1 时, 下一拍继续写一个 halfword.
        end

        CMD_READ: begin
          read_addr <= make_addr(ba, active_row[ba], a[COL_W-1:0]); // 保存要读取的内部地址.
          read_delay <= (cas_latency > 2'd1) ? (cas_latency - 2'd2) : 2'd0; // 根据 CAS latency 安排返回时机.
          read_pending <= 1'b1; // 标记有一个 READ 正在等待返回.
          read_second_valid <= 1'b0; // 新 READ 开始时清掉旧的第二拍 burst 标记.
        end

        default: begin
          // 未识别命令当作 NOP, 包括 cs 未选中时的大多数编码.
        end
      endcase
    end
  end

endmodule // sdram_x16
