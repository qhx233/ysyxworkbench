
// ============================================================================
// ysyx_26060181
// ----------------------------------------------------------------------------
// 这是当前 NPC 的 CPU 顶层模块.
//
// 设计风格:
//   1. 非流水线, 单发射, 顺序执行.
//   2. 用一个 4 状态 FSM 控制一条指令的生命周期:
//        ST_IF_REQ  : 发起取指地址请求
//        ST_IF_RSP  : 等待指令返回, 并完成译码/执行非访存指令
//        ST_MEM_REQ : 对 load/store 发起数据访存请求
//        ST_MEM_RSP : 等待 load 数据或 store 写响应
//   3. IFU 前面接了 simple_icache.
//   4. I-cache 对 SDRAM 取指支持 16B cache line 和 4-beat AXI burst.
//   5. LSU 仍保持单拍读写, 简单可靠.
// ============================================================================
module ysyx_26060181(
    input         clock,       // SoC 提供的时钟
    input         reset,       // 高有效复位
    input         io_interrupt,// 外部中断输入; 当前 CPU 内部暂未真正使用

    // ========================================================
    // AXI4 Master Interface (CPU 作为主设备，主动读写外部 SoC)
    // ========================================================
    // AW Channel
    input         io_master_awready, // 外部 slave 是否接受写地址
    output        io_master_awvalid, // CPU 是否发出有效写地址
    output [31:0] io_master_awaddr,  // 写地址
    output [ 3:0] io_master_awid,    // 写事务 ID; 当前固定 0
    output [ 7:0] io_master_awlen,   // 写 burst 长度; 0 表示 1 beat
    output [ 2:0] io_master_awsize,  // 每个写 beat 的字节数编码
    output [ 1:0] io_master_awburst, // 写 burst 类型; 当前写通道固定单拍
    // W Channel
    input         io_master_wready, // 外部 slave 是否接受写数据
    output        io_master_wvalid, // CPU 是否发出有效写数据
    output [31:0] io_master_wdata,  // 写数据
    output [ 3:0] io_master_wstrb,  // 字节写掩码
    output        io_master_wlast,  // 写 burst 最后一拍; 单拍写恒为 1
    // B Channel
    output        io_master_bready, // CPU 是否准备接受写响应
    input         io_master_bvalid, // 外部 slave 是否给出写响应
    input  [ 1:0] io_master_bresp,  // 写响应状态; 00 表示 OKAY
    input  [ 3:0] io_master_bid,    // 写响应 ID; 当前未使用
    // AR Channel
    input         io_master_arready, // 外部 slave 是否接受读地址
    output        io_master_arvalid, // CPU 是否发出有效读地址
    output [31:0] io_master_araddr,  // 读地址
    output [ 3:0] io_master_arid,    // 读事务 ID; 当前固定 0
    output [ 7:0] io_master_arlen,   // 读 burst 长度; I-cache miss 时可为 3
    output [ 2:0] io_master_arsize,  // 每个读 beat 的字节数编码
    output [ 1:0] io_master_arburst, // 读 burst 类型; I-cache 可发 INCR
    // R Channel
    output        io_master_rready, // CPU 是否准备接受读数据
    input         io_master_rvalid, // 外部 slave 是否给出读数据
    input  [ 1:0] io_master_rresp,  // 读响应状态; 00 表示 OKAY
    input  [31:0] io_master_rdata,  // 读数据
    input         io_master_rlast,  // 读 burst 最后一拍
    input  [ 3:0] io_master_rid,    // 读响应 ID; 当前未使用

    // ========================================================
    // AXI4 Slave Interface (外部 SoC 主动读写 CPU，这里不用)
    // ========================================================
    // AW Channel
    output        io_slave_awready, // 以下 io_slave_* 是 CPU 作为 AXI slave 的接口
    input         io_slave_awvalid,
    input  [31:0] io_slave_awaddr,
    input  [ 3:0] io_slave_awid,
    input  [ 7:0] io_slave_awlen,
    input  [ 2:0] io_slave_awsize,
    input  [ 1:0] io_slave_awburst,
    // W Channel
    output        io_slave_wready,
    input         io_slave_wvalid,
    input  [31:0] io_slave_wdata,
    input  [ 3:0] io_slave_wstrb,
    input         io_slave_wlast,
    // B Channel
    input         io_slave_bready,
    output        io_slave_bvalid,
    output [ 1:0] io_slave_bresp,
    output [ 3:0] io_slave_bid,
    // AR Channel
    output        io_slave_arready,
    input         io_slave_arvalid,
    input  [31:0] io_slave_araddr,
    input  [ 3:0] io_slave_arid,
    input  [ 7:0] io_slave_arlen,
    input  [ 2:0] io_slave_arsize,
    input  [ 1:0] io_slave_arburst,
    // R Channel
    input         io_slave_rready,
    output        io_slave_rvalid,
    output [ 1:0] io_slave_rresp,
    output [31:0] io_slave_rdata,
    output        io_slave_rlast,
    output [ 3:0] io_slave_rid
);

    // =================================================================
    // 时钟与复位映射
    // =================================================================
    wire clk = clock;               // 给内部逻辑使用的时钟别名
    wire rst = reset;               // 给内部逻辑使用的复位别名
    wire unused_intr = io_interrupt;// 防止 io_interrupt 未使用导致 lint 报警

    // =================================================================
    // AXI4 协议扩展信号绑定 (Tie-off)
    // =================================================================
    
    // --- 1. Master 闲置信号绑定 ---
    assign io_master_awid    = 4'd0;        // 不支持多 outstanding 写事务, ID 固定 0
    assign io_master_awlen   = 8'd0;        // 写通道单拍: beat 数 = awlen + 1 = 1
    assign io_master_awsize  = mem_axi_size;// SB/SH/SW 分别对应 1/2/4 字节
    assign io_master_awburst = 2'b00;       // 单拍写使用 FIXED 即可
    assign io_master_wlast   = 1'b1;        // 单拍写的数据同时也是最后一拍

    assign io_master_arid    = 4'd0;        // 不支持多 outstanding 读事务, ID 固定 0
    assign io_master_arlen   = arb_arlen;   // 读长度由仲裁器选择: LSU 单拍, I-cache 可 burst
    assign io_master_arsize  = arb_arsize;  // 读 beat 大小由仲裁器选择
    assign io_master_arburst = arb_arburst; // 读 burst 类型由仲裁器选择

    // --- 2. Slave 信号全部锁死赋 0 (修复 PINNOTFOUND 报错) ---
    assign io_slave_awready = 1'b0; // 当前不接受外部 master 对 CPU 的写地址
    assign io_slave_wready  = 1'b0; // 当前不接受外部 master 对 CPU 的写数据
    assign io_slave_bvalid  = 1'b0; // 因为不接受写, 所以永远不返回写响应
    assign io_slave_bresp   = 2'b00;// 响应内容无效, 固定 0 防悬空
    assign io_slave_bid     = 4'd0; // 响应 ID 无效, 固定 0 防悬空

    assign io_slave_arready = 1'b0; // 当前不接受外部 master 对 CPU 的读地址
    assign io_slave_rvalid  = 1'b0; // 因为不接受读, 所以永远不返回读数据
    assign io_slave_rresp   = 2'b00;// 读响应内容无效, 固定 0 防悬空
    assign io_slave_rdata   = 32'b0;// 读数据无效, 固定 0 防悬空
    assign io_slave_rlast   = 1'b0; // 读 burst 结束标志无效, 固定 0 防悬空
    assign io_slave_rid     = 4'd0; // 读响应 ID 无效, 固定 0 防悬空


    // =================================================================
    // DPI-C 引入
    // =================================================================
    import "DPI-C" function void npc_trap(input int a0_val);
    import "DPI-C" function void npc_itrace_commit(input int pc, input int inst, input int dnpc);
    import "DPI-C" function void npc_perf_event(input int event_id, input int data);
    import "DPI-C" function void npc_perf_commit(input int category, input int cycles);
    import "DPI-C" function int npc_reset_pc();

    reg [31:0] pc;                  // 当前指令 PC
    localparam ST_IF_REQ = 2'b00, ST_IF_RSP = 2'b01, ST_MEM_REQ = 2'b10, ST_MEM_RSP = 2'b11;
    reg [1:0] state;                // CPU 主控 FSM 当前状态

    // ---------------- IFU 到 I-cache 的 CPU 侧接口 ----------------
    wire        ifu_arvalid, ifu_arready; // IFU 读地址 valid/ready
    wire [31:0] ifu_araddr;               // IFU 要读取的指令地址, 也就是 pc
    wire        ifu_rvalid, ifu_rready;   // I-cache 返回指令的 valid/ready
    wire [31:0] ifu_rdata;                // I-cache 返回的 32 位指令

    // ---------------- I-cache 到仲裁器/外部总线的内存侧接口 --------
    wire        ifu_mem_arvalid, ifu_mem_arready; // I-cache miss 时发往总线的读地址握手
    wire [31:0] ifu_mem_araddr;                   // miss fill 的读地址
    wire [7:0]  ifu_mem_arlen;                    // I-cache burst 长度, SDRAM line fill 时为 3
    wire [2:0]  ifu_mem_arsize;                   // I-cache 每拍 4B, 所以通常为 3'b010
    wire [1:0]  ifu_mem_arburst;                  // SDRAM line fill 使用 INCR burst
    wire        ifu_mem_rvalid, ifu_mem_rready;   // I-cache 接收总线读数据握手
    wire [31:0] ifu_mem_rdata;                    // I-cache 从总线收到的一个 beat 数据
    wire        ifu_mem_rlast;                    // 当前 beat 是否为 burst 最后一拍

    // IFU 只读指令, 没有写通道; 这些信号保留为 0 只是为了结构完整
    wire        ifu_awvalid = 1'b0; wire [31:0] ifu_awaddr  = 32'b0;
    wire        ifu_wvalid  = 1'b0; wire [31:0] ifu_wdata   = 32'b0;
    wire [3:0]  ifu_wstrb   = 4'b0; wire        ifu_bready  = 1'b0;

    // ---------------- LSU 数据访存接口 ----------------
    wire        lsu_arvalid, lsu_arready; // load 读地址 valid/ready
    wire [31:0] lsu_araddr;               // load 地址
    wire        lsu_rvalid, lsu_rready;   // load 读数据 valid/ready
    wire [31:0] lsu_rdata;                // load 原始读数据
    wire        lsu_awvalid, lsu_awready; // store 写地址 valid/ready
    wire [31:0] lsu_awaddr;               // store 地址
    wire        lsu_wvalid, lsu_wready;   // store 写数据 valid/ready
    wire [31:0] lsu_wdata;                // store 写数据
    wire [3:0]  lsu_wstrb;                // store 字节写掩码
    wire        lsu_bvalid, lsu_bready;   // store 写响应 valid/ready

    // AXI/类 AXI 握手成功条件: valid 和 ready 同时为 1
    wire ifu_hsk_ar = ifu_arvalid && ifu_arready; // IFU 取指地址被接受
    wire ifu_hsk_r  = ifu_rvalid  && ifu_rready;  // IFU 指令数据被 CPU 接受
    wire lsu_hsk_ar = lsu_arvalid && lsu_arready; // LSU load 地址被接受
    wire lsu_hsk_r  = lsu_rvalid  && lsu_rready;  // LSU load 数据被接受
    wire lsu_hsk_aw = lsu_awvalid && lsu_awready; // LSU store 地址被接受
    wire lsu_hsk_w  = lsu_wvalid  && lsu_wready;  // LSU store 数据被接受
    wire lsu_hsk_b  = lsu_bvalid  && lsu_bready;  // LSU store 响应被接受

    reg [31:0] inst_reg; // 保存最近一次取回来的指令; 等待 MEM 阶段时仍需使用
    always @(posedge clk) begin
        if (rst) inst_reg <= 32'h00000013; // 复位时放一条 NOP, 避免 X 传播
        else if (ifu_hsk_r) inst_reg <= ifu_rdata; // 指令返回时锁存
    end
    // IF_RSP 且本周期刚拿到指令时, 直接使用 ifu_rdata; 否则使用锁存的 inst_reg.
    wire [31:0] inst = (state == ST_IF_RSP && ifu_hsk_r) ? ifu_rdata : inst_reg;

    // 译码逻辑
    wire [6:0] opcode = inst[6:0];      // RISC-V opcode 字段
    wire [2:0] funct3 = inst[14:12];    // RISC-V funct3 字段
    wire [6:0] funct7 = inst[31:25];    // RISC-V funct7 字段
    wire op_load = (opcode == 7'b0000011), op_store = (opcode == 7'b0100011); // 识别 load/store
    wire is_mem_inst = op_load || op_store; // 访存指令需要额外进入 MEM_REQ/MEM_RSP
    wire [2:0] mem_axi_size = (funct3[1:0] == 2'b00) ? 3'b000 :
                              (funct3[1:0] == 2'b01) ? 3'b001 : 3'b010;

    wire [31:0] rs1_data, rs2_data, alu_result, a0_val; // 寄存器读数据、ALU 输出、a0 监视值
    wire in_uart = (alu_result[31:12] == 20'h10000);    // UART MMIO 地址段
    wire in_spi = (alu_result[31:12] == 20'h10001);     // SPI MMIO 地址段
    wire in_ps2 = (alu_result[31:12] == 20'h10011);     // PS2 MMIO 地址段
    wire in_flash = (alu_result[31:28] == 4'h3);        // Flash 地址段
    wire in_clint = (alu_result[31:24] == 8'h02);       // CLINT 地址段
    wire in_psram = (alu_result[31:29] == 3'b100);      // PSRAM 地址段
    wire in_sdram = (alu_result[31:29] == 3'b101);      // SDRAM 地址段
    wire [31:0] mem_addr   = alu_result & ~32'h3;       // 普通内存访问按 4B 对齐
    wire [31:0] bus_addr   = (in_uart || in_spi || in_ps2 || in_psram) ? alu_result : mem_addr; // 部分外设保留原始地址低位
    wire [1:0]  mem_offset = alu_result[1:0];           // 低两位用于字节/半字选择
    
    wire [7:0] wmask = (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : // SB 写 1 字节
                       (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : // SH 写 2 字节
                       (funct3 == 3'b010) ? 8'b0000_1111 : 8'b0;           // SW 写 4 字节
    wire [31:0] store_data_raw = (funct3 == 3'b000) ? {24'b0, rs2_data[7:0]}  :
                                 (funct3 == 3'b001) ? {16'b0, rs2_data[15:0]} : rs2_data;
    wire [31:0] wdata = store_data_raw << {mem_offset, 3'b000}; // 根据地址低位把 store 数据移到目标 byte lane

    reg aw_done, w_done; // store 的 AW/W 两个通道可独立握手, 需要分别记录完成情况
    always @(posedge clk) begin
        if (rst) begin state <= ST_IF_REQ; aw_done <= 1'b0; w_done <= 1'b0; end 
        else begin
            case (state)
                ST_IF_REQ:  if (ifu_hsk_ar) state <= ST_IF_RSP; // 取指地址被接受后, 等指令数据
                ST_IF_RSP:  if (ifu_hsk_r) state <= is_mem_inst ? ST_MEM_REQ : ST_IF_REQ; // 指令返回后决定是否需要数据访存
                ST_MEM_REQ: begin
                    if (op_load) begin if (lsu_hsk_ar) state <= ST_MEM_RSP; end // load 地址发出后, 等待读数据
                    else if (op_store) begin
                        if (lsu_hsk_aw) aw_done <= 1'b1; // store 写地址通道完成
                        if (lsu_hsk_w)  w_done  <= 1'b1; // store 写数据通道完成
                        if ((aw_done || lsu_hsk_aw) && (w_done || lsu_hsk_w)) begin
                            state <= ST_MEM_RSP; aw_done <= 1'b0; w_done <= 1'b0;
                        end
                    end
                end
                ST_MEM_RSP: begin
                    if (op_load && lsu_hsk_r) state <= ST_IF_REQ;  // load 数据回来后, 当前指令提交
                    if (op_store && lsu_hsk_b) state <= ST_IF_REQ; // store 响应回来后, 当前指令提交
                end
                default: state <= ST_IF_REQ;
            endcase
        end
    end

    wire commit_non_mem = (state == ST_IF_RSP)  && ifu_hsk_r && !is_mem_inst; // 非访存指令在取回指令当拍提交
    wire commit_mem     = (state == ST_MEM_RSP) && (op_load ? lsu_hsk_r : lsu_hsk_b); // 访存指令在数据/响应回来时提交
    wire stall = !(commit_non_mem || commit_mem); // 没有提交时, PC 和寄存器写回都停住

    assign ifu_arvalid = (state == ST_IF_REQ);              // 只有取指请求状态才发 IFU 地址
    assign ifu_araddr  = pc;                                // 取指地址就是当前 PC
    assign ifu_rready  = (state == ST_IF_RSP);              // 只有等待取指响应状态才接收指令
    assign lsu_arvalid = (state == ST_MEM_REQ) && op_load;  // load 在 MEM_REQ 发读地址
    assign lsu_araddr  = bus_addr;                          // load 地址来自 ALU 结果处理后的 bus_addr
    assign lsu_rready  = (state == ST_MEM_RSP) && op_load;  // load 在 MEM_RSP 接收读数据
    assign lsu_awvalid = (state == ST_MEM_REQ) && op_store && !aw_done; // store 地址没完成时持续发 AW
    assign lsu_awaddr  = bus_addr;                          // store 地址来自 ALU 结果处理后的 bus_addr
    assign lsu_wvalid  = (state == ST_MEM_REQ) && op_store && !w_done;  // store 数据没完成时持续发 W
    assign lsu_wdata   = wdata;                             // store 写数据已按 byte lane 移位
    assign lsu_wstrb   = wmask[3:0];                        // 低 4 位作为 32-bit 数据总线字节写掩码
    assign lsu_bready  = (state == ST_MEM_RSP) && op_store; // store 在 MEM_RSP 接收 B 响应

`ifdef PS2_DEBUG
    reg [7:0] ps2_dbg_read_count;
    always @(posedge clk) begin
        if (rst) begin
            ps2_dbg_read_count <= 8'b0;
        end else if (lsu_hsk_ar && lsu_araddr[31:12] == 20'h10011 && ps2_dbg_read_count < 8'd64) begin
            $display("[CPU] ps2 read addr=0x%08x pc=0x%08x inst=0x%08x", lsu_araddr, pc, inst);
            ps2_dbg_read_count <= ps2_dbg_read_count + 1'b1;
        end
    end
`endif

    wire [4:0] rs1_idx = inst[19:15], rs2_idx = inst[24:20], rd_idx  = inst[11:7];
`ifdef SDRAM_DEBUG
    reg [7:0] sdram_dbg_count;
    reg [31:0] sdram_dbg_awaddr;
    reg [31:0] sdram_dbg_wdata;
    reg [3:0]  sdram_dbg_wstrb;
    wire sdram_dbg_load_hit = lsu_hsk_r && op_load &&
        (lsu_araddr >= 32'ha00053f0 && lsu_araddr < 32'ha0005910);
    wire sdram_dbg_store_hit = lsu_hsk_b && op_store &&
        (sdram_dbg_awaddr >= 32'ha00053f0 && sdram_dbg_awaddr < 32'ha0005910);
    always @(posedge clk) begin
        if (rst) begin
            sdram_dbg_count <= 8'b0;
            sdram_dbg_awaddr <= 32'b0;
            sdram_dbg_wdata <= 32'b0;
            sdram_dbg_wstrb <= 4'b0;
        end else begin
            if (lsu_hsk_aw) sdram_dbg_awaddr <= lsu_awaddr;
            if (lsu_hsk_w) begin
                sdram_dbg_wdata <= lsu_wdata;
                sdram_dbg_wstrb <= lsu_wstrb;
            end
            if (sdram_dbg_count < 8'd160 && (sdram_dbg_load_hit || sdram_dbg_store_hit)) begin
            if (sdram_dbg_load_hit) begin
                $display("[SDRAM-CPU] load  pc=0x%08x inst=0x%08x addr=0x%08x data=0x%08x rd=%0d",
                         pc, inst, lsu_araddr, lsu_rdata, rd_idx);
            end else begin
                $display("[SDRAM-CPU] store pc=0x%08x inst=0x%08x addr=0x%08x data=0x%08x strb=0x%x",
                         pc, inst, sdram_dbg_awaddr, sdram_dbg_wdata, sdram_dbg_wstrb);
            end
            sdram_dbg_count <= sdram_dbg_count + 1'b1;
            end
        end
    end
`endif
    wire [31:0] imm_I = {{20{inst[31]}}, inst[31:20]};                    // I 型立即数, 符号扩展
    wire [31:0] imm_S = {{20{inst[31]}}, inst[31:25], inst[11:7]};         // S 型立即数, 用于 store
    wire [31:0] imm_B = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0}; // B 型分支偏移, 最低位固定 0
    wire [31:0] imm_U = {inst[31:12], 12'b0};                              // U 型立即数, 低 12 位补 0
    wire [31:0] imm_J = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0}; // J 型跳转偏移

    wire op_lui = (opcode == 7'b0110111), op_auipc = (opcode == 7'b0010111), op_jal = (opcode == 7'b1101111); // U/J 类指令识别
    wire op_jalr = (opcode == 7'b1100111), op_branch = (opcode == 7'b1100011), op_imm = (opcode == 7'b0010011); // 跳转/分支/立即数计算
    wire op_reg = (opcode == 7'b0110011), op_system = (opcode == 7'b1110011), is_ebreak = (inst == 32'h00100073); // 寄存器计算/system/ebreak
    localparam PERF_CAT_ALU    = 32'd0;
    localparam PERF_CAT_LOAD   = 32'd1;
    localparam PERF_CAT_STORE  = 32'd2;
    localparam PERF_CAT_BRANCH = 32'd3;
    localparam PERF_CAT_JUMP   = 32'd4;
    localparam PERF_CAT_CSR    = 32'd5;
    localparam PERF_CAT_SYSTEM = 32'd6;
    localparam PERF_CAT_OTHER  = 32'd7;
    // 性能统计用的指令分类; 不参与功能正确性, 只给 npc_perf_commit 使用.
    wire [31:0] perf_inst_category =
        op_load                    ? PERF_CAT_LOAD   :
        op_store                   ? PERF_CAT_STORE  :
        op_branch                  ? PERF_CAT_BRANCH :
        (op_jal || op_jalr)        ? PERF_CAT_JUMP   :
        (op_system && funct3 != 0) ? PERF_CAT_CSR    :
        op_system                  ? PERF_CAT_SYSTEM :
        (op_lui || op_auipc || op_imm || op_reg) ? PERF_CAT_ALU : PERF_CAT_OTHER;

    wire alu_eq = (rs1_data == rs2_data);                       // BEQ/BNE 使用
    wire alu_lt = ($signed(rs1_data) < $signed(rs2_data));       // BLT/BGE 有符号比较
    wire alu_ltu = (rs1_data < rs2_data);                        // BLTU/BGEU 无符号比较
    wire branch_taken = op_branch && ((funct3 == 3'b000 && alu_eq) || (funct3 == 3'b001 && !alu_eq) || 
                                      (funct3 == 3'b100 && alu_lt) || (funct3 == 3'b101 && !alu_lt) || 
                                      (funct3 == 3'b110 && alu_ltu) || (funct3 == 3'b111 && !alu_ltu));

    wire [31:0] snpc = pc + 32'h8;       // 顺序下一条指令地址
    wire [31:0] csr_mtvec, csr_mepc;     // CSR 模块输出的 trap 入口和异常返回地址
    wire is_ecall = op_system && (funct3 == 3'b000) && (inst[31:20] == 12'b0); // ECALL 指令
    wire is_mret  = op_system && (funct3 == 3'b000) && (inst[31:20] == 12'b001100000010); // MRET 指令
    // dnpc 是提交后写入 PC 的下一 PC.
    wire [31:0] dnpc = (is_ecall) ? csr_mtvec : (is_mret) ? csr_mepc : (op_jal) ? (pc + imm_J) :
                       (op_jalr) ? ((rs1_data + imm_I) & ~32'h1) : (branch_taken) ? (pc + imm_B) : snpc;

    wire axi_read_fault = io_master_rvalid && io_master_rready && (io_master_rresp != 2'b00);  // 外部读响应非 OKAY
    wire axi_write_fault = io_master_bvalid && io_master_bready && (io_master_bresp != 2'b00); // 外部写响应非 OKAY
    wire access_fault = axi_read_fault || axi_write_fault; // 当前简化处理: 读/写错误都视为 access fault
    wire [31:0] access_fault_cause = axi_write_fault ? 32'd7 : op_load ? 32'd5 : 32'd1; // store/load/取指 fault cause

    always @(posedge clk) begin
        if (rst) pc <= npc_reset_pc();      // 复位后 PC 由 C++ DPI 决定, flash boot 时为 Flash 地址
        else if (access_fault) pc <= csr_mtvec; // 访问错误按异常处理跳转到 mtvec
        else if (!stall) pc <= dnpc;        // 只有当前指令提交时才更新 PC
    end

    wire is_sub = (op_reg && funct7[5]) || op_branch; // SUB/分支比较复用减法控制位
    wire is_sra = (funct7[5] && (op_reg || op_imm) && funct3 == 3'b101); // SRA/SRAI 识别
    wire [3:0] alu_op = (op_lui || op_auipc || op_jal || op_load || op_store) ? 4'b0000 : { (is_sub || is_sra), funct3 }; // ALU 控制码
    wire [31:0] alu_src1 = (op_auipc) ? pc : (op_lui) ? 32'b0 : rs1_data; // AUIPC 用 PC, LUI 用 0, 其他用 rs1
    wire [31:0] alu_src2 = (op_imm || op_load || op_jalr) ? imm_I : (op_store) ? imm_S : (op_lui || op_auipc) ? imm_U : rs2_data; // 第二操作数选择
    alu u_alu (.src1(alu_src1), .src2(alu_src2), .alu_op(alu_op), .result(alu_result)); 

    // =======================================================================
    // 仲裁器：连接 IFU/LSU，将其合并为单路 AXI4-Lite
    // =======================================================================
    wire        arb_arvalid, arb_arready; // IFU/LSU 合并后的读地址握手
    wire [31:0] arb_araddr;               // IFU/LSU 合并后的读地址
    wire [7:0]  arb_arlen;                // 合并后的读 burst 长度
    wire [2:0]  arb_arsize;               // 合并后的读 beat 大小
    wire [1:0]  arb_arburst;              // 合并后的读 burst 类型
    wire        arb_rvalid,  arb_rready;  // 合并后的读数据握手
    wire [31:0] arb_rdata;                // 合并后的读数据
    wire        arb_rlast;                // 合并后的读 burst 最后一拍
    wire        arb_awvalid, arb_awready; // 合并后的写地址握手; 当前只有 LSU 写
    wire [31:0] arb_awaddr;               // 合并后的写地址
    wire        arb_wvalid,  arb_wready;  // 合并后的写数据握手; 当前只有 LSU 写
    wire [31:0] arb_wdata;                // 合并后的写数据
    wire [3:0]  arb_wstrb;                // 合并后的写掩码
    wire        arb_bvalid,  arb_bready;  // 合并后的写响应握手

    simple_icache #(
        .LINE_NUM(16)
    ) u_icache (
        .clk(clk),
        .rst(rst),
        .cpu_arvalid(ifu_arvalid),
        .cpu_arready(ifu_arready),
        .cpu_araddr(ifu_araddr),
        .cpu_rvalid(ifu_rvalid),
        .cpu_rready(ifu_rready),
        .cpu_rdata(ifu_rdata),
        .mem_arvalid(ifu_mem_arvalid),
        .mem_arready(ifu_mem_arready),
        .mem_araddr(ifu_mem_araddr),
        .mem_arlen(ifu_mem_arlen),
        .mem_arsize(ifu_mem_arsize),
        .mem_arburst(ifu_mem_arburst),
        .mem_rvalid(ifu_mem_rvalid),
        .mem_rready(ifu_mem_rready),
        .mem_rdata(ifu_mem_rdata),
        .mem_rlast(ifu_mem_rlast)
    );

    axi_arbiter u_arbiter (
        .clk(clk), .rst(rst),
        .ifu_arvalid(ifu_mem_arvalid), .ifu_arready(ifu_mem_arready), .ifu_araddr(ifu_mem_araddr), .ifu_arlen(ifu_mem_arlen), .ifu_arsize(ifu_mem_arsize), .ifu_arburst(ifu_mem_arburst), .ifu_rvalid(ifu_mem_rvalid), .ifu_rready(ifu_mem_rready), .ifu_rdata(ifu_mem_rdata), .ifu_rlast(ifu_mem_rlast),
        .lsu_arvalid(lsu_arvalid), .lsu_arready(lsu_arready), .lsu_araddr(lsu_araddr), .lsu_arsize(mem_axi_size), .lsu_rvalid(lsu_rvalid), .lsu_rready(lsu_rready), .lsu_rdata(lsu_rdata),
        .lsu_awvalid(lsu_awvalid), .lsu_awready(lsu_awready), .lsu_awaddr(lsu_awaddr), .lsu_wvalid(lsu_wvalid), .lsu_wready(lsu_wready), .lsu_wdata(lsu_wdata), .lsu_wstrb(lsu_wstrb), .lsu_bvalid(lsu_bvalid), .lsu_bready(lsu_bready),
        .mem_arvalid(arb_arvalid), .mem_arready(arb_arready), .mem_araddr(arb_araddr), .mem_arlen(arb_arlen), .mem_arsize(arb_arsize), .mem_arburst(arb_arburst), .mem_rvalid(arb_rvalid), .mem_rready(arb_rready), .mem_rdata(arb_rdata), .mem_rlast(arb_rlast),
        .mem_awvalid(arb_awvalid), .mem_awready(arb_awready), .mem_awaddr(arb_awaddr), .mem_wvalid(arb_wvalid), .mem_wready(arb_wready), .mem_wdata(arb_wdata), .mem_wstrb(arb_wstrb), .mem_bvalid(arb_bvalid), .mem_bready(arb_bready)
    );

    // =======================================================================
    // 内部 CLINT 模块实例
    // =======================================================================
    wire        clint_arvalid, clint_arready; wire [31:0] clint_araddr;
    wire        clint_rvalid,  clint_rready;  wire [31:0] clint_rdata;
    wire        clint_awvalid, clint_awready; wire [31:0] clint_awaddr;
    wire        clint_wvalid,  clint_wready;  wire [31:0] clint_wdata; wire [3:0] clint_wstrb;
    wire        clint_bvalid,  clint_bready;

    axi_clint u_clint (
        .clk(clk), .rst(rst),
        .arvalid(clint_arvalid), .arready(clint_arready), .araddr(clint_araddr), .rvalid(clint_rvalid), .rready(clint_rready), .rdata(clint_rdata),
        .awvalid(clint_awvalid), .awready(clint_awready), .awaddr(clint_awaddr), .wvalid(clint_wvalid), .wready(clint_wready), .wdata(clint_wdata), .wstrb(clint_wstrb), .bvalid(clint_bvalid), .bready(clint_bready)
    );

    // =======================================================================
    // 地址分发器 (Xbar): 决定去内部 CLINT 还是去外部 ysyxSoCFull
    // =======================================================================
    wire sel_clint = (arb_araddr[31:24] == 8'h02);   // 读地址落在 0x02xx_xxxx 时走内部 CLINT
    wire sel_clint_w = (arb_awaddr[31:24] == 8'h02); // 写地址落在 0x02xx_xxxx 时走内部 CLINT
    
    wire sel_ext   = !sel_clint;   // 非 CLINT 读请求走外部 ysyxSoC 总线
    wire sel_ext_w = !sel_clint_w; // 非 CLINT 写请求走外部 ysyxSoC 总线

    // AR
    assign clint_arvalid = arb_arvalid && sel_clint;     // 选中 CLINT 时把 AR valid 发给 CLINT
    assign clint_araddr  = arb_araddr;                   // CLINT 读地址
    assign io_master_arvalid = arb_arvalid && sel_ext;   // 选中外部总线时把 AR valid 发给 ysyxSoC
    assign io_master_araddr  = arb_araddr;               // 外部读地址
    assign arb_arready = sel_clint ? clint_arready : (sel_ext ? io_master_arready : 1'b0); // 返回被选 slave 的 ready

    // R
    assign arb_rvalid = clint_rvalid | io_master_rvalid;         // 任一返回通道有效, 仲裁后读数据有效
    assign arb_rdata  = clint_rvalid ? clint_rdata : io_master_rdata; // CLINT 优先; 正常不会和外部同时返回
    assign arb_rlast  = clint_rvalid ? 1'b1 : io_master_rlast;   // CLINT 永远单拍, 所以 rlast 视为 1
    assign clint_rready = arb_rready && clint_rvalid;            // 只有 CLINT 正在返回时才把 ready 给 CLINT
    assign io_master_rready = arb_rready && io_master_rvalid;    // 只有外部正在返回时才把 ready 给外部总线

    // AW
    assign clint_awvalid = arb_awvalid && sel_clint_w;   // 选中 CLINT 时把 AW valid 发给 CLINT
    assign clint_awaddr  = arb_awaddr;                   // CLINT 写地址
    assign io_master_awvalid = arb_awvalid && sel_ext_w; // 选中外部总线时把 AW valid 发给 ysyxSoC
    assign io_master_awaddr  = arb_awaddr;               // 外部写地址
    assign arb_awready = sel_clint_w ? clint_awready : (sel_ext_w ? io_master_awready : 1'b0); // 返回被选 slave 的 AW ready

    // W
    assign clint_wvalid = arb_wvalid && sel_clint_w;     // 选中 CLINT 时把 W valid 发给 CLINT
    assign clint_wdata  = arb_wdata;                     // CLINT 写数据
    assign clint_wstrb  = arb_wstrb;                     // CLINT 写掩码
    assign io_master_wvalid = arb_wvalid && sel_ext_w;   // 选中外部总线时把 W valid 发给 ysyxSoC
    assign io_master_wdata  = arb_wdata;                 // 外部写数据
    assign io_master_wstrb  = arb_wstrb;                 // 外部写掩码
    assign arb_wready = sel_clint_w ? clint_wready : (sel_ext_w ? io_master_wready : 1'b0); // 返回被选 slave 的 W ready

    // B
    assign arb_bvalid = clint_bvalid | io_master_bvalid;      // 任一写响应有效, 仲裁后 B valid 有效
    assign clint_bready = arb_bready && clint_bvalid;         // CLINT 返回时把 B ready 给 CLINT
    assign io_master_bready = arb_bready && io_master_bvalid; // 外部返回时把 B ready 给外部总线

    // =======================================================================
    // 数据通路与 CSR
    // =======================================================================
    wire [7:0] byte_data = (mem_offset == 2'b00) ? lsu_rdata[7:0] : (mem_offset == 2'b01) ? lsu_rdata[15:8] : (mem_offset == 2'b10) ? lsu_rdata[23:16] : lsu_rdata[31:24]; // 从 32-bit load 数据中选出目标字节
    wire [15:0] half_data = (mem_offset[1] == 1'b0) ? lsu_rdata[15:0] : lsu_rdata[31:16]; // 从 32-bit load 数据中选出目标半字
    wire [31:0] ext_mem_rdata = (funct3 == 3'b000) ? {{24{byte_data[7]}}, byte_data} : (funct3 == 3'b001) ? {{16{half_data[15]}}, half_data} : (funct3 == 3'b010) ? lsu_rdata : (funct3 == 3'b100) ? {24'b0, byte_data} : (funct3 == 3'b101) ? {16'b0, half_data} : 32'b0; // LB/LH/LW/LBU/LHU 扩展结果

    wire is_csr = op_system && (funct3 != 3'b000); // SYSTEM 且 funct3 非 0 表示 CSR 指令
    wire is_csrrw = is_csr && (funct3 == 3'b001);  // CSRRW
    wire is_csrrs = is_csr && (funct3 == 3'b010);  // CSRRS
    wire [11:0] csr_addr = inst[31:20];            // CSR 地址字段
    reg [63:0] mcycle_counter; always @(posedge clk) if(rst) mcycle_counter <= 0; else mcycle_counter <= mcycle_counter + 1; // 简单 mcycle 计数器

    reg [31:0] mstatus, mtvec, mepc, mcause;       // 当前实现的一小组机器模式 CSR
    assign csr_mtvec = mtvec;                      // ECALL 时跳转目标
    assign csr_mepc = mepc;                        // MRET 时返回目标
    wire csr_wen = (is_csrrw) || (is_csrrs && rs1_idx != 0); // CSRRS x0 不应写 CSR

    wire [31:0] csr_rdata_internal;                // CSR 读数据
    wire [31:0] csr_wdata = (is_csrrw) ? rs1_data : (is_csrrs) ? (csr_rdata_internal | rs1_data) : 32'b0; // CSR 写数据

    always @(posedge clk) begin
        if (rst) begin mstatus <= 32'h1800; mtvec <= 32'b0; mepc <= 32'b0; mcause <= 32'b0; end 
        else if (access_fault) begin
            mepc <= pc;
            mcause <= access_fault_cause;
        end else if (!stall) begin
            if (is_ecall) begin mepc <= pc; mcause <= 32'd11; end // ECALL 保存异常 PC 和 cause
            else if (csr_wen) begin
                 if      (csr_addr == 12'h300) mstatus <= csr_wdata;
                 else if (csr_addr == 12'h305) mtvec   <= csr_wdata;
                 else if (csr_addr == 12'h341) mepc    <= csr_wdata;
                 else if (csr_addr == 12'h342) mcause  <= csr_wdata;
            end
        end
    end

    assign csr_rdata_internal = (csr_addr == 12'h300) ? mstatus : (csr_addr == 12'h305) ? mtvec : // mstatus/mtvec
                                (csr_addr == 12'h341) ? mepc : (csr_addr == 12'h342) ? mcause : 
                                (csr_addr == 12'hB00 || csr_addr == 12'hC00 || csr_addr == 12'hC01) ? mcycle_counter[31:0] : 
                                (csr_addr == 12'hB80 || csr_addr == 12'hC80 || csr_addr == 12'hC81) ? mcycle_counter[63:32] : 
                                (csr_addr == 12'hF11) ? 32'h79737978 : (csr_addr == 12'hF12) ? 32'd100022721 : 32'b0; // mvendorid/marchid

    // MMIO 防打扰机制（DiffTest）
    wire is_mmio = is_mem_inst && (in_uart || in_spi || in_ps2 || in_flash || in_clint || in_sdram); // DiffTest 中这些访问需要跳过或特殊处理
    wire is_skip_csr = is_csr && (
        csr_addr == 12'hB00 || csr_addr == 12'hC00 || csr_addr == 12'hC01 || 
        csr_addr == 12'hB80 || csr_addr == 12'hC80 || csr_addr == 12'hC81 ||
        csr_addr == 12'hF11 || csr_addr == 12'hF12
    );
    
    reg skip_flag;
    always @(posedge clk) begin
        if (rst) skip_flag <= 1'b0;
        else skip_flag <= (!stall) && (is_mmio || is_skip_csr);
    end

    export "DPI-C" function npc_check_skip;
    function int npc_check_skip; return skip_flag ? 32'd1 : 32'd0; endfunction

    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg || is_csr); // 需要写 rd 的指令集合
    wire [31:0] rf_wdata = (is_csr) ? csr_rdata_internal : (op_jal || op_jalr) ? snpc : (op_load) ? ext_mem_rdata : alu_result; // 写回数据选择

    regfile u_regfile (.clk(clk), .rst(rst), .wen(rf_wen && !stall && !access_fault), .waddr(rd_idx), .wdata(rf_wdata), .raddr1(rs1_idx), .raddr2(rs2_idx), .rdata1(rs1_data), .rdata2(rs2_data), .a0_val(a0_val));

    export "DPI-C" function npc_read_gpr; function int npc_read_gpr(input int idx); return u_regfile.rf[idx]; endfunction // C++ difftest/调试读取 GPR
    export "DPI-C" function npc_read_pc;  function int npc_read_pc; return pc; endfunction // C++ difftest/调试读取 PC

    reg commit_flag; always @(posedge clk) if (rst) commit_flag <= 0; else commit_flag <= !stall; // 标记上一拍是否有指令提交
    export "DPI-C" function npc_is_commit; function int npc_is_commit; return commit_flag ? 32'd1 : 32'd0; endfunction // C++ 查询提交状态

    localparam PERF_EVT_IFU_FETCH        = 32'd0;
    localparam PERF_EVT_LSU_LOAD_DATA    = 32'd1;
    localparam PERF_EVT_LSU_STORE_DONE   = 32'd2;
    localparam PERF_EVT_EXU_DONE         = 32'd3;
    localparam PERF_EVT_ICACHE_HIT       = 32'd4;
    localparam PERF_EVT_ICACHE_MISS      = 32'd5;
    localparam PERF_EVT_IFU_WAIT_REQ     = 32'd10;
    localparam PERF_EVT_IFU_WAIT_RSP     = 32'd11;
    localparam PERF_EVT_IFU_WAIT_LSU_LD  = 32'd12;
    localparam PERF_EVT_IFU_WAIT_LSU_ST  = 32'd13;
    localparam PERF_EVT_LSU_LOAD_LAT     = 32'd20;
    localparam PERF_EVT_LSU_STORE_LAT    = 32'd21;

    reg [31:0] perf_inst_cycles;
    reg [31:0] perf_lsu_cycles;
    always @(posedge clk) begin
        if (rst) begin
            perf_inst_cycles <= 32'b0;
            perf_lsu_cycles <= 32'b0;
        end else begin
            if (ifu_hsk_r) npc_perf_event(PERF_EVT_IFU_FETCH, 32'd0);              // 取到一条指令
            if (lsu_hsk_r && op_load) npc_perf_event(PERF_EVT_LSU_LOAD_DATA, 32'd0); // load 返回一次数据
            if (lsu_hsk_b && op_store) npc_perf_event(PERF_EVT_LSU_STORE_DONE, 32'd0); // store 完成一次写响应
            if (commit_non_mem) npc_perf_event(PERF_EVT_EXU_DONE, 32'd0);          // 非访存指令执行完成

            if (!ifu_hsk_r) begin
                if (state == ST_IF_REQ) npc_perf_event(PERF_EVT_IFU_WAIT_REQ, 32'd0);
                else if (state == ST_IF_RSP) npc_perf_event(PERF_EVT_IFU_WAIT_RSP, 32'd0);
                else if (state == ST_MEM_REQ || state == ST_MEM_RSP) begin
                    if (op_load) npc_perf_event(PERF_EVT_IFU_WAIT_LSU_LD, 32'd0);
                    else npc_perf_event(PERF_EVT_IFU_WAIT_LSU_ST, 32'd0);
                end
            end

            if (commit_non_mem || commit_mem) begin
                npc_perf_commit(perf_inst_category, perf_inst_cycles + 32'd1);
                perf_inst_cycles <= 32'b0;
            end else begin
                perf_inst_cycles <= perf_inst_cycles + 32'd1;
            end

            if (state == ST_MEM_REQ || state == ST_MEM_RSP) begin
                if (commit_mem) begin
                    npc_perf_event(op_load ? PERF_EVT_LSU_LOAD_LAT : PERF_EVT_LSU_STORE_LAT,
                                   perf_lsu_cycles + 32'd1);
                    perf_lsu_cycles <= 32'b0;
                end else begin
                    perf_lsu_cycles <= perf_lsu_cycles + 32'd1;
                end
            end else begin
                perf_lsu_cycles <= 32'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && !stall) begin
            if (is_ebreak) npc_trap(a0_val); // ebreak 时通知 C++ 仿真环境结束
            npc_itrace_commit(pc, inst, dnpc); // 每次提交都把 PC/inst/dnpc 交给 C++ 做 trace
        end
    end
endmodule

module simple_icache #(
    parameter LINE_NUM = 16,       // cache line 数量
    parameter INDEX_BITS = 4,      // 16 lines 需要 4 位 index
    parameter WORDS_PER_LINE = 4   // 每个 line 存 4 个 32-bit word, 即 16B
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_arvalid,
    output wire        cpu_arready,
    input  wire [31:0] cpu_araddr,
    output wire        cpu_rvalid,
    input  wire        cpu_rready,
    output wire [31:0] cpu_rdata,
    output wire        mem_arvalid,
    input  wire        mem_arready,
    output wire [31:0] mem_araddr,
    output wire [7:0]  mem_arlen,
    output wire [2:0]  mem_arsize,
    output wire [1:0]  mem_arburst,
    input  wire        mem_rvalid,
    output wire        mem_rready,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rlast
);
    import "DPI-C" function void npc_perf_event(input int event_id, input int data);

    localparam PERF_EVT_ICACHE_HIT = 32'd4;      // DPI 性能事件: I-cache hit
    localparam PERF_EVT_ICACHE_MISS = 32'd5;     // DPI 性能事件: I-cache miss
    localparam PERF_EVT_ICACHE_MISS_LAT = 32'd22;// DPI 性能事件: I-cache miss latency
    localparam WORD_INDEX_BITS = 2;              // 4 words/line 需要 2 位 word index
    localparam OFFSET_BITS = 2 + WORD_INDEX_BITS;// byte offset 2 位 + word offset 2 位 = 16B line
    localparam TAG_BITS = 32 - OFFSET_BITS - INDEX_BITS; // 剩余高位作为 tag
    localparam [1:0] LAST_WORD = 2'd3;           // 4 word line 的最后一个 word index
    localparam ST_IDLE = 2'b00, ST_MISS_AR = 2'b01, ST_MISS_R = 2'b10, ST_RESP = 2'b11; // cache 内部 FSM

    reg [1:0] state;          // cache 当前状态
    reg [31:0] req_addr;      // miss 请求锁存地址
    reg [31:0] resp_data;     // 返回给 CPU 的指令数据
    reg [31:0] miss_cycles;   // 统计 miss 从发起到完成花费的周期数
    reg [1:0]  fill_word;     // 当前正在填充 line 中的第几个 word
    reg        resp_valid;    // 返回给 CPU 的响应 valid

    reg [31:0] data_array [0:LINE_NUM-1][0:WORDS_PER_LINE-1]; // cache 数据阵列: line x word
    reg [TAG_BITS-1:0] tag_array [0:LINE_NUM-1];              // 每个 line 的 tag
    reg valid_array [0:LINE_NUM-1];                           // 每个 line 的 valid 位

    wire [INDEX_BITS-1:0] req_index = cpu_araddr[OFFSET_BITS + INDEX_BITS - 1:OFFSET_BITS]; // 当前 CPU 请求映射到哪个 line
    wire [TAG_BITS-1:0] req_tag = cpu_araddr[31:OFFSET_BITS + INDEX_BITS];                   // 当前 CPU 请求 tag
    wire [WORD_INDEX_BITS-1:0] req_word = cpu_araddr[3:2];                                   // 当前 CPU 请求 line 内第几个 word
    wire [INDEX_BITS-1:0] fill_index = req_addr[OFFSET_BITS + INDEX_BITS - 1:OFFSET_BITS];   // miss fill 写入哪个 line
    wire [TAG_BITS-1:0] fill_tag = req_addr[31:OFFSET_BITS + INDEX_BITS];                    // miss fill 对应 tag
    wire [WORD_INDEX_BITS-1:0] fill_req_word = req_addr[3:2];                                // CPU 真正需要的 word
    wire req_cacheable = (cpu_araddr[31:29] == 3'b101);                                      // 目前只缓存 SDRAM 取指
    wire fill_cacheable = (req_addr[31:29] == 3'b101);                                       // 锁存请求是否为 SDRAM
    wire hit = req_cacheable && valid_array[req_index] && (tag_array[req_index] == req_tag); // valid 且 tag 匹配即命中

    assign cpu_arready = (state == ST_IDLE) && !resp_valid; // cache 空闲且无未消费响应时接受 CPU 请求
    assign cpu_rvalid = resp_valid;                         // resp_valid 直接作为 CPU 侧 rvalid
    assign cpu_rdata = resp_data;                            // 返回给 CPU 的指令

    assign mem_arvalid = (state == ST_MISS_AR);              // miss 后进入 ST_MISS_AR 发总线读地址
    assign mem_araddr = fill_cacheable ? {req_addr[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}} : {req_addr[31:2], 2'b00}; // SDRAM line fill 16B 对齐; 非缓存单拍 4B 对齐
    assign mem_arlen = fill_cacheable ? 8'd3 : 8'd0;         // SDRAM line fill 使用 4 beat burst; 非缓存单拍
    assign mem_arsize = 3'b010;                              // 每 beat 4 字节
    assign mem_arburst = fill_cacheable ? 2'b01 : 2'b00;     // SDRAM 用 INCR burst; 非缓存用 FIXED
    assign mem_rready = (state == ST_MISS_R);                // 等待读数据状态才接收总线 R 通道

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;       // 复位后 cache 空闲
            req_addr <= 32'b0;      // 清空锁存请求
            resp_data <= 32'b0;     // 清空响应数据
            miss_cycles <= 32'b0;   // 清空 miss 周期计数
            fill_word <= 2'b0;      // 从 line 第 0 个 word 开始填
            resp_valid <= 1'b0;     // 复位后没有有效响应
            for (i = 0; i < LINE_NUM; i = i + 1) begin
                valid_array[i] <= 1'b0;
                tag_array[i] <= {TAG_BITS{1'b0}};
                data_array[i][0] <= 32'b0;
                data_array[i][1] <= 32'b0;
                data_array[i][2] <= 32'b0;
                data_array[i][3] <= 32'b0;
            end
        end else begin
            if (resp_valid && cpu_rready) begin
                resp_valid <= 1'b0;                 // CPU 消费响应后撤销 valid
                if (state == ST_RESP) state <= ST_IDLE; // 响应被消费后回到空闲
            end

            case (state)
                ST_IDLE: begin
                    if (cpu_arvalid && cpu_arready) begin // 接受一个新的取指请求
                        req_addr <= cpu_araddr;           // 锁存请求地址, miss fill 后续使用
                        if (hit) begin
                            resp_data <= data_array[req_index][req_word]; // 命中: 直接取出 line 内目标 word
                            resp_valid <= 1'b1;                           // 下一步返回 CPU
                            npc_perf_event(PERF_EVT_ICACHE_HIT, 32'd0);   // 通知 C++ 统计 hit
                        end else begin
                            npc_perf_event(PERF_EVT_ICACHE_MISS, 32'd0);  // 通知 C++ 统计 miss
                            miss_cycles <= 32'd1;                         // 从 miss 发生开始计时
                            fill_word <= 2'b0;                            // burst fill 从第 0 个 word 开始
                            state <= ST_MISS_AR;                          // 去总线发读地址
                        end
                    end
                end

                ST_MISS_AR: begin
                    miss_cycles <= miss_cycles + 32'd1; // 等待 AR ready 的每周期都计入 miss penalty
                    if (mem_arvalid && mem_arready) begin
                        state <= ST_MISS_R;            // 地址握手完成, 开始等待读数据 beat
                    end
                end

                ST_MISS_R: begin
                    miss_cycles <= miss_cycles + 32'd1; // 等待/接收 R beat 的周期计入 miss penalty
                    if (mem_rvalid && mem_rready) begin
                        if (fill_cacheable) begin
                            data_array[fill_index][fill_word] <= mem_rdata; // 当前 beat 写入 cache line
                            tag_array[fill_index] <= fill_tag;              // 更新 tag
                            valid_array[fill_index] <= 1'b1;                // 标记 line 有效
                            if (fill_word == fill_req_word) begin
                                resp_data <= mem_rdata; // 如果这个 beat 正好是 CPU 要的指令, 先保存起来
                            end
                            if (mem_rlast || fill_word == LAST_WORD) begin
                                resp_valid <= 1'b1;                                      // 整个 line 填完后再回复 CPU
                                npc_perf_event(PERF_EVT_ICACHE_MISS_LAT, miss_cycles);    // 上报 miss latency
                                state <= ST_RESP;                                        // 等 CPU 消费响应
                            end else begin
                                fill_word <= fill_word + 2'd1; // 继续接收下一个 burst beat
                            end
                        end else begin
                            resp_data <= mem_rdata;                                      // 非缓存访问: 单拍数据直接返回
                            resp_valid <= 1'b1;                                          // 通知 CPU 数据有效
                            npc_perf_event(PERF_EVT_ICACHE_MISS_LAT, miss_cycles);        // 非缓存单拍也统计为 miss latency
                            state <= ST_RESP;                                            // 等 CPU 消费响应
                        end
                    end
                end

                ST_RESP: begin
                    if (!resp_valid) begin // 防御性状态: 如果响应已经撤销, 回到空闲
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

// =======================================================================
// 保留的仲裁器模块 (axi_arbiter)
// =======================================================================
module axi_arbiter(
    input wire clk, input wire rst,
    input  wire        ifu_arvalid, output wire        ifu_arready, input  wire [31:0] ifu_araddr, input wire [7:0] ifu_arlen, input wire [2:0] ifu_arsize, input wire [1:0] ifu_arburst, output wire        ifu_rvalid,  input  wire        ifu_rready,  output wire [31:0] ifu_rdata, output wire ifu_rlast,
    input  wire        lsu_arvalid, output wire        lsu_arready, input  wire [31:0] lsu_araddr, input wire [2:0] lsu_arsize, output wire        lsu_rvalid,  input  wire        lsu_rready,  output wire [31:0] lsu_rdata,
    input  wire        lsu_awvalid, output wire        lsu_awready, input  wire [31:0] lsu_awaddr, input  wire        lsu_wvalid,  output wire        lsu_wready,  input  wire [31:0] lsu_wdata, input  wire [3:0]  lsu_wstrb, output wire        lsu_bvalid,  input  wire        lsu_bready,
    output wire        mem_arvalid, input  wire        mem_arready, output wire [31:0] mem_araddr, output wire [7:0] mem_arlen, output wire [2:0] mem_arsize, output wire [1:0] mem_arburst, input  wire        mem_rvalid,  output wire        mem_rready,  input  wire [31:0] mem_rdata, input wire mem_rlast,
    output wire        mem_awvalid, input  wire        mem_awready, output wire [31:0] mem_awaddr, output wire        mem_wvalid,  input  wire        mem_wready,  output wire [31:0] mem_wdata, output wire [3:0]  mem_wstrb, input  wire        mem_bvalid,  output wire        mem_bready
);
    // 写通道当前只有 LSU 使用, 所以不需要复杂仲裁, 直接透传.
    assign mem_awvalid = lsu_awvalid; // LSU store AW valid 直接发到下游
    assign lsu_awready = mem_awready; // 下游 AW ready 直接返回 LSU
    assign mem_awaddr  = lsu_awaddr;  // LSU store 地址
    assign mem_wvalid  = lsu_wvalid;  // LSU store W valid 直接发到下游
    assign lsu_wready  = mem_wready;  // 下游 W ready 直接返回 LSU
    assign mem_wdata   = lsu_wdata;   // LSU store 数据
    assign mem_wstrb = lsu_wstrb;     // LSU store 字节写掩码
    assign lsu_bvalid  = mem_bvalid;  // 下游 B valid 直接返回 LSU
    assign mem_bready  = lsu_bready;  // LSU B ready 直接发到下游

    localparam IDLE = 2'b00, GRANT_LSU = 2'b01, GRANT_IFU = 2'b10; // 读通道仲裁状态
    reg [1:0] state; // 当前读通道授权给谁
    always @(posedge clk) begin
        if (rst) state <= IDLE; // 复位后无授权
        else case (state)
            IDLE:      if (lsu_arvalid) state <= GRANT_LSU; else if (ifu_arvalid) state <= GRANT_IFU; // LSU 优先于 IFU
            GRANT_LSU: if (mem_rvalid && mem_rready && mem_rlast) state <= IDLE; // LSU 读响应最后一拍完成后释放
            GRANT_IFU: if (mem_rvalid && mem_rready && mem_rlast) state <= IDLE; // IFU burst 最后一拍完成后释放
            default:   state <= IDLE; // 防御性恢复
        endcase
    end
    assign mem_arvalid = (state == GRANT_LSU) ? lsu_arvalid : (state == GRANT_IFU) ? ifu_arvalid : 1'b0; // 只把被授权方的 AR valid 发出去
    assign mem_araddr  = (state == GRANT_LSU) ? lsu_araddr  : (state == GRANT_IFU) ? ifu_araddr  : 32'b0; // 选择读地址
    assign mem_arlen   = (state == GRANT_LSU) ? 8'd0       : (state == GRANT_IFU) ? ifu_arlen   : 8'd0; // LSU 单拍, IFU 可 burst
    assign mem_arsize  = (state == GRANT_LSU) ? lsu_arsize  : (state == GRANT_IFU) ? ifu_arsize  : 3'b010; // 选择 beat 大小
    assign mem_arburst = (state == GRANT_LSU) ? 2'b00      : (state == GRANT_IFU) ? ifu_arburst : 2'b00; // LSU FIXED, IFU 可 INCR
    assign lsu_arready = (state == GRANT_LSU) ? mem_arready : 1'b0; // 只有授权 LSU 时才给 LSU ready
    assign ifu_arready = (state == GRANT_IFU) ? mem_arready : 1'b0; // 只有授权 IFU 时才给 IFU ready
    assign mem_rready  = (state == GRANT_LSU) ? lsu_rready : (state == GRANT_IFU) ? ifu_rready : 1'b0; // 下游 R ready 来自被授权方
    assign lsu_rvalid  = (state == GRANT_LSU) ? mem_rvalid : 1'b0; // 只有授权 LSU 时 R valid 返回 LSU
    assign ifu_rvalid  = (state == GRANT_IFU) ? mem_rvalid : 1'b0; // 只有授权 IFU 时 R valid 返回 IFU
    assign ifu_rlast   = (state == GRANT_IFU) ? mem_rlast : 1'b0;  // IFU 需要 rlast 判断 burst 是否完成
    assign lsu_rdata   = mem_rdata; // 读数据总线直接广播给 LSU, valid 控制是否有效
    assign ifu_rdata = mem_rdata;   // 读数据总线直接广播给 IFU, valid 控制是否有效
endmodule

// =======================================================================
// 重获新生的内部计时器 (axi_clint)
// =======================================================================
module axi_clint(
    input clk, input rst,
    input  wire        arvalid, output wire        arready, input  wire [31:0] araddr, output wire        rvalid,  input  wire        rready,  output wire [31:0] rdata,
    input  wire        awvalid, output wire        awready, input  wire [31:0] awaddr, input  wire        wvalid,  output wire        wready,  input  wire [31:0] wdata, input wire [3:0] wstrb, output wire        bvalid,  input  wire        bready
);
    reg [63:0] mtime; always @(posedge clk) begin if (rst) mtime <= 64'b0; else mtime <= mtime + 64'd1; end // 简单递增的 mtime

    reg rvalid_reg;       // CLINT 读响应 valid 寄存器
    reg [31:0] rdata_reg; // CLINT 读响应数据寄存器
    always @(posedge clk) begin
         if (rst) begin rvalid_reg <= 0; rdata_reg <= 0; end // 复位清空读响应
         else if (arvalid && !rvalid_reg) begin
             rvalid_reg <= 1; // 接受读请求后, 下一步保持 rvalid 等 CPU 接收
             if (araddr[7:0] == 8'h48 || araddr[7:0] == 8'hF8) rdata_reg <= mtime[31:0]; // mtime 低 32 位
             else if (araddr[7:0] == 8'h4C || araddr[7:0] == 8'hFC) rdata_reg <= mtime[63:32]; // mtime 高 32 位
             else rdata_reg <= 32'h0; // 其他 CLINT 地址暂未实现
         end else if (rvalid_reg && rready) rvalid_reg <= 0; // CPU 接收后撤销 rvalid
    end
    assign arready = !rvalid_reg; // 没有未完成读响应时才能接收新读请求
    assign rvalid = rvalid_reg;   // 输出读响应 valid
    assign rdata = rdata_reg;     // 输出读响应数据

    reg bvalid_reg; // CLINT 写响应 valid 寄存器
    always @(posedge clk) begin
         if (rst) bvalid_reg <= 0; // 复位清空写响应
         else if (awvalid && wvalid && !bvalid_reg) begin bvalid_reg <= 1; end // 同时看到 AW/W 后返回 B
         else if (bvalid_reg && bready) bvalid_reg <= 0; // CPU 接收 B 后撤销
    end
    assign awready = !bvalid_reg; // 没有未完成写响应时接受写地址
    assign wready = !bvalid_reg;  // 没有未完成写响应时接受写数据
    assign bvalid = bvalid_reg;   // 输出写响应 valid
endmodule
