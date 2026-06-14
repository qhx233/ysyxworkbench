
module ysyx_23060000(
    input         clock,
    input         reset,
    input         io_interrupt,

    // ========================================================
    // AXI4 Master Interface (CPU 作为主设备，主动读写外部 SoC)
    // ========================================================
    // AW Channel
    input         io_master_awready,
    output        io_master_awvalid,
    output [31:0] io_master_awaddr,
    output [ 3:0] io_master_awid,
    output [ 7:0] io_master_awlen,
    output [ 2:0] io_master_awsize,
    output [ 1:0] io_master_awburst,
    // W Channel
    input         io_master_wready,
    output        io_master_wvalid,
    output [31:0] io_master_wdata,
    output [ 3:0] io_master_wstrb,
    output        io_master_wlast,
    // B Channel
    output        io_master_bready,
    input         io_master_bvalid,
    input  [ 1:0] io_master_bresp,
    input  [ 3:0] io_master_bid,
    // AR Channel
    input         io_master_arready,
    output        io_master_arvalid,
    output [31:0] io_master_araddr,
    output [ 3:0] io_master_arid,
    output [ 7:0] io_master_arlen,
    output [ 2:0] io_master_arsize,
    output [ 1:0] io_master_arburst,
    // R Channel
    output        io_master_rready,
    input         io_master_rvalid,
    input  [ 1:0] io_master_rresp,
    input  [31:0] io_master_rdata,
    input         io_master_rlast,
    input  [ 3:0] io_master_rid,

    // ========================================================
    // AXI4 Slave Interface (外部 SoC 主动读写 CPU，这里不用)
    // ========================================================
    // AW Channel
    output        io_slave_awready,
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
    wire clk = clock;
    wire rst = reset;
    wire unused_intr = io_interrupt; 

    // =================================================================
    // AXI4 协议扩展信号绑定 (Tie-off)
    // =================================================================
    
    // --- 1. Master 闲置信号绑定 ---
    assign io_master_awid    = 4'd0;
    assign io_master_awlen   = 8'd0;
    assign io_master_awsize  = mem_axi_size;
    assign io_master_awburst = 2'b00;
    assign io_master_wlast   = 1'b1;   // 单拍传输必须拉高

    assign io_master_arid    = 4'd0;
    assign io_master_arlen   = 8'd0;
    assign io_master_arsize  = ((state == ST_MEM_REQ) && op_load) ? mem_axi_size : 3'b010;
    assign io_master_arburst = 2'b00;

    // --- 2. Slave 信号全部锁死赋 0 (修复 PINNOTFOUND 报错) ---
    assign io_slave_awready = 1'b0;
    assign io_slave_wready  = 1'b0;
    assign io_slave_bvalid  = 1'b0;
    assign io_slave_bresp   = 2'b00;
    assign io_slave_bid     = 4'd0;

    assign io_slave_arready = 1'b0;
    assign io_slave_rvalid  = 1'b0;
    assign io_slave_rresp   = 2'b00;
    assign io_slave_rdata   = 32'b0;
    assign io_slave_rlast   = 1'b0;
    assign io_slave_rid     = 4'd0;


    // =================================================================
    // DPI-C 引入
    // =================================================================
    import "DPI-C" function void npc_trap(input int a0_val);
    import "DPI-C" function void npc_itrace_commit(input int pc, input int inst, input int dnpc);
    import "DPI-C" function int npc_reset_pc();

    reg [31:0] pc; 
    localparam ST_IF_REQ = 2'b00, ST_IF_RSP = 2'b01, ST_MEM_REQ = 2'b10, ST_MEM_RSP = 2'b11;
    reg [1:0] state;

    wire        ifu_arvalid, ifu_arready; wire [31:0] ifu_araddr;
    wire        ifu_rvalid, ifu_rready;   wire [31:0] ifu_rdata;
    wire        ifu_awvalid = 1'b0; wire [31:0] ifu_awaddr  = 32'b0;
    wire        ifu_wvalid  = 1'b0; wire [31:0] ifu_wdata   = 32'b0;
    wire [3:0]  ifu_wstrb   = 4'b0; wire        ifu_bready  = 1'b0;

    wire        lsu_arvalid, lsu_arready; wire [31:0] lsu_araddr;
    wire        lsu_rvalid, lsu_rready;   wire [31:0] lsu_rdata;
    wire        lsu_awvalid, lsu_awready; wire [31:0] lsu_awaddr;
    wire        lsu_wvalid, lsu_wready;   wire [31:0] lsu_wdata;
    wire [3:0]  lsu_wstrb;
    wire        lsu_bvalid, lsu_bready;

    wire ifu_hsk_ar = ifu_arvalid && ifu_arready; wire ifu_hsk_r  = ifu_rvalid  && ifu_rready;
    wire lsu_hsk_ar = lsu_arvalid && lsu_arready; wire lsu_hsk_r  = lsu_rvalid  && lsu_rready;
    wire lsu_hsk_aw = lsu_awvalid && lsu_awready; wire lsu_hsk_w  = lsu_wvalid  && lsu_wready;
    wire lsu_hsk_b  = lsu_bvalid  && lsu_bready;

    reg [31:0] inst_reg;
    always @(posedge clk) begin
        if (rst) inst_reg <= 32'h00000013;
        else if (ifu_hsk_r) inst_reg <= ifu_rdata;
    end
    wire [31:0] inst = (state == ST_IF_RSP && ifu_hsk_r) ? ifu_rdata : inst_reg;

    // 译码逻辑
    wire [6:0] opcode = inst[6:0]; wire [2:0] funct3 = inst[14:12]; wire [6:0] funct7 = inst[31:25];
    wire op_load = (opcode == 7'b0000011), op_store = (opcode == 7'b0100011);
    wire is_mem_inst = op_load || op_store;
    wire [2:0] mem_axi_size = (funct3[1:0] == 2'b00) ? 3'b000 :
                              (funct3[1:0] == 2'b01) ? 3'b001 : 3'b010;

    wire [31:0] rs1_data, rs2_data, alu_result, a0_val;
    wire in_uart = (alu_result[31:12] == 20'h10000);
    wire in_spi = (alu_result[31:12] == 20'h10001);
    wire in_ps2 = (alu_result[31:12] == 20'h10011);
    wire in_flash = (alu_result[31:28] == 4'h3);
    wire in_clint = (alu_result[31:24] == 8'h02);
    wire in_psram = (alu_result[31:29] == 3'b100);
    wire in_sdram = (alu_result[31:29] == 3'b101);
    wire [31:0] mem_addr   = alu_result & ~32'h3;
    wire [31:0] bus_addr   = (in_uart || in_spi || in_ps2 || in_psram) ? alu_result : mem_addr;
    wire [1:0]  mem_offset = alu_result[1:0];
    
    wire [7:0] wmask = (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : 
                       (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : 
                       (funct3 == 3'b010) ? 8'b0000_1111 : 8'b0;
    wire [31:0] store_data_raw = (funct3 == 3'b000) ? {24'b0, rs2_data[7:0]}  :
                                 (funct3 == 3'b001) ? {16'b0, rs2_data[15:0]} : rs2_data;
    wire [31:0] wdata = store_data_raw << {mem_offset, 3'b000};

    reg aw_done, w_done;
    always @(posedge clk) begin
        if (rst) begin state <= ST_IF_REQ; aw_done <= 1'b0; w_done <= 1'b0; end 
        else begin
            case (state)
                ST_IF_REQ:  if (ifu_hsk_ar) state <= ST_IF_RSP;
                ST_IF_RSP:  if (ifu_hsk_r) state <= is_mem_inst ? ST_MEM_REQ : ST_IF_REQ;
                ST_MEM_REQ: begin
                    if (op_load) begin if (lsu_hsk_ar) state <= ST_MEM_RSP; end 
                    else if (op_store) begin
                        if (lsu_hsk_aw) aw_done <= 1'b1;
                        if (lsu_hsk_w)  w_done  <= 1'b1;
                        if ((aw_done || lsu_hsk_aw) && (w_done || lsu_hsk_w)) begin
                            state <= ST_MEM_RSP; aw_done <= 1'b0; w_done <= 1'b0;
                        end
                    end
                end
                ST_MEM_RSP: begin
                    if (op_load && lsu_hsk_r) state <= ST_IF_REQ;
                    if (op_store && lsu_hsk_b) state <= ST_IF_REQ;
                end
                default: state <= ST_IF_REQ;
            endcase
        end
    end

    wire commit_non_mem = (state == ST_IF_RSP)  && ifu_hsk_r && !is_mem_inst;
    wire commit_mem     = (state == ST_MEM_RSP) && (op_load ? lsu_hsk_r : lsu_hsk_b);
    wire stall = !(commit_non_mem || commit_mem);

    assign ifu_arvalid = (state == ST_IF_REQ); assign ifu_araddr  = pc; assign ifu_rready  = (state == ST_IF_RSP);
    assign lsu_arvalid = (state == ST_MEM_REQ) && op_load; assign lsu_araddr  = bus_addr; assign lsu_rready  = (state == ST_MEM_RSP) && op_load;
    assign lsu_awvalid = (state == ST_MEM_REQ) && op_store && !aw_done; assign lsu_awaddr  = bus_addr;
    assign lsu_wvalid  = (state == ST_MEM_REQ) && op_store && !w_done; assign lsu_wdata   = wdata; assign lsu_wstrb   = wmask[3:0];
    assign lsu_bready  = (state == ST_MEM_RSP) && op_store;

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
    wire [31:0] imm_I = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_S = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_B = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_U = {inst[31:12], 12'b0};
    wire [31:0] imm_J = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};

    wire op_lui = (opcode == 7'b0110111), op_auipc = (opcode == 7'b0010111), op_jal = (opcode == 7'b1101111);
    wire op_jalr = (opcode == 7'b1100111), op_branch = (opcode == 7'b1100011), op_imm = (opcode == 7'b0010011);
    wire op_reg = (opcode == 7'b0110011), op_system = (opcode == 7'b1110011), is_ebreak = (inst == 32'h00100073);

    wire alu_eq = (rs1_data == rs2_data), alu_lt = ($signed(rs1_data) < $signed(rs2_data)), alu_ltu = (rs1_data < rs2_data);
    wire branch_taken = op_branch && ((funct3 == 3'b000 && alu_eq) || (funct3 == 3'b001 && !alu_eq) || 
                                      (funct3 == 3'b100 && alu_lt) || (funct3 == 3'b101 && !alu_lt) || 
                                      (funct3 == 3'b110 && alu_ltu) || (funct3 == 3'b111 && !alu_ltu));

    wire [31:0] snpc = pc + 32'h4; wire [31:0] csr_mtvec, csr_mepc;
    wire is_ecall = op_system && (funct3 == 3'b000) && (inst[31:20] == 12'b0);
    wire is_mret  = op_system && (funct3 == 3'b000) && (inst[31:20] == 12'b001100000010);
    wire [31:0] dnpc = (is_ecall) ? csr_mtvec : (is_mret) ? csr_mepc : (op_jal) ? (pc + imm_J) :
                       (op_jalr) ? ((rs1_data + imm_I) & ~32'h1) : (branch_taken) ? (pc + imm_B) : snpc;

    wire axi_read_fault = io_master_rvalid && io_master_rready && (io_master_rresp != 2'b00);
    wire axi_write_fault = io_master_bvalid && io_master_bready && (io_master_bresp != 2'b00);
    wire access_fault = axi_read_fault || axi_write_fault;
    wire [31:0] access_fault_cause = axi_write_fault ? 32'd7 : op_load ? 32'd5 : 32'd1;

    always @(posedge clk) begin
        if (rst) pc <= npc_reset_pc();
        else if (access_fault) pc <= 32'h0;
        else if (!stall) pc <= dnpc;
    end

    wire is_sub = (op_reg && funct7[5]) || op_branch; wire is_sra = (funct7[5] && (op_reg || op_imm) && funct3 == 3'b101);
    wire [3:0] alu_op = (op_lui || op_auipc || op_jal || op_load || op_store) ? 4'b0000 : { (is_sub || is_sra), funct3 };
    wire [31:0] alu_src1 = (op_auipc) ? pc : (op_lui) ? 32'b0 : rs1_data;
    wire [31:0] alu_src2 = (op_imm || op_load || op_jalr) ? imm_I : (op_store) ? imm_S : (op_lui || op_auipc) ? imm_U : rs2_data;
    alu u_alu (.src1(alu_src1), .src2(alu_src2), .alu_op(alu_op), .result(alu_result)); 

    // =======================================================================
    // 仲裁器：连接 IFU/LSU，将其合并为单路 AXI4-Lite
    // =======================================================================
    wire        arb_arvalid, arb_arready; wire [31:0] arb_araddr;
    wire        arb_rvalid,  arb_rready;  wire [31:0] arb_rdata;
    wire        arb_awvalid, arb_awready; wire [31:0] arb_awaddr;
    wire        arb_wvalid,  arb_wready;  wire [31:0] arb_wdata; wire [3:0] arb_wstrb;
    wire        arb_bvalid,  arb_bready;

    axi_arbiter u_arbiter (
        .clk(clk), .rst(rst),
        .ifu_arvalid(ifu_arvalid), .ifu_arready(ifu_arready), .ifu_araddr(ifu_araddr), .ifu_rvalid(ifu_rvalid), .ifu_rready(ifu_rready), .ifu_rdata(ifu_rdata),
        .lsu_arvalid(lsu_arvalid), .lsu_arready(lsu_arready), .lsu_araddr(lsu_araddr), .lsu_rvalid(lsu_rvalid), .lsu_rready(lsu_rready), .lsu_rdata(lsu_rdata),
        .lsu_awvalid(lsu_awvalid), .lsu_awready(lsu_awready), .lsu_awaddr(lsu_awaddr), .lsu_wvalid(lsu_wvalid), .lsu_wready(lsu_wready), .lsu_wdata(lsu_wdata), .lsu_wstrb(lsu_wstrb), .lsu_bvalid(lsu_bvalid), .lsu_bready(lsu_bready),
        .mem_arvalid(arb_arvalid), .mem_arready(arb_arready), .mem_araddr(arb_araddr), .mem_rvalid(arb_rvalid), .mem_rready(arb_rready), .mem_rdata(arb_rdata),
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
    wire sel_clint = (arb_araddr[31:24] == 8'h02);
    wire sel_clint_w = (arb_awaddr[31:24] == 8'h02);
    
    wire sel_ext   = !sel_clint;
    wire sel_ext_w = !sel_clint_w;

    // AR
    assign clint_arvalid = arb_arvalid && sel_clint;
    assign clint_araddr  = arb_araddr;
    assign io_master_arvalid = arb_arvalid && sel_ext;
    assign io_master_araddr  = arb_araddr;
    assign arb_arready = sel_clint ? clint_arready : (sel_ext ? io_master_arready : 1'b0);

    // R
    assign arb_rvalid = clint_rvalid | io_master_rvalid;
    assign arb_rdata  = clint_rvalid ? clint_rdata : io_master_rdata;
    assign clint_rready = arb_rready && clint_rvalid;
    assign io_master_rready = arb_rready && io_master_rvalid;

    // AW
    assign clint_awvalid = arb_awvalid && sel_clint_w;
    assign clint_awaddr  = arb_awaddr;
    assign io_master_awvalid = arb_awvalid && sel_ext_w;
    assign io_master_awaddr  = arb_awaddr;
    assign arb_awready = sel_clint_w ? clint_awready : (sel_ext_w ? io_master_awready : 1'b0);

    // W
    assign clint_wvalid = arb_wvalid && sel_clint_w;
    assign clint_wdata  = arb_wdata;
    assign clint_wstrb  = arb_wstrb;
    assign io_master_wvalid = arb_wvalid && sel_ext_w;
    assign io_master_wdata  = arb_wdata;
    assign io_master_wstrb  = arb_wstrb;
    assign arb_wready = sel_clint_w ? clint_wready : (sel_ext_w ? io_master_wready : 1'b0);

    // B
    assign arb_bvalid = clint_bvalid | io_master_bvalid;
    assign clint_bready = arb_bready && clint_bvalid;
    assign io_master_bready = arb_bready && io_master_bvalid;

    // =======================================================================
    // 数据通路与 CSR
    // =======================================================================
    wire [7:0] byte_data = (mem_offset == 2'b00) ? lsu_rdata[7:0] : (mem_offset == 2'b01) ? lsu_rdata[15:8] : (mem_offset == 2'b10) ? lsu_rdata[23:16] : lsu_rdata[31:24];
    wire [15:0] half_data = (mem_offset[1] == 1'b0) ? lsu_rdata[15:0] : lsu_rdata[31:16];
    wire [31:0] ext_mem_rdata = (funct3 == 3'b000) ? {{24{byte_data[7]}}, byte_data} : (funct3 == 3'b001) ? {{16{half_data[15]}}, half_data} : (funct3 == 3'b010) ? lsu_rdata : (funct3 == 3'b100) ? {24'b0, byte_data} : (funct3 == 3'b101) ? {16'b0, half_data} : 32'b0;

    wire is_csr = op_system && (funct3 != 3'b000); wire is_csrrw = is_csr && (funct3 == 3'b001); wire is_csrrs = is_csr && (funct3 == 3'b010);
    wire [11:0] csr_addr = inst[31:20]; 
    reg [63:0] mcycle_counter; always @(posedge clk) if(rst) mcycle_counter <= 0; else mcycle_counter <= mcycle_counter + 1; 

    reg [31:0] mstatus, mtvec, mepc, mcause;  assign csr_mtvec = mtvec; assign csr_mepc = mepc;
    wire csr_wen = (is_csrrw) || (is_csrrs && rs1_idx != 0);

    wire [31:0] csr_rdata_internal; 
    wire [31:0] csr_wdata = (is_csrrw) ? rs1_data : (is_csrrs) ? (csr_rdata_internal | rs1_data) : 32'b0;

    always @(posedge clk) begin
        if (rst) begin mstatus <= 32'h1800; mtvec <= 32'b0; mepc <= 32'b0; mcause <= 32'b0; end 
        else if (access_fault) begin
            mepc <= pc;
            mcause <= access_fault_cause;
        end else if (!stall) begin
            if (is_ecall) begin mepc <= pc; mcause <= 32'd11; end 
            else if (csr_wen) begin
                 if      (csr_addr == 12'h300) mstatus <= csr_wdata;
                 else if (csr_addr == 12'h305) mtvec   <= csr_wdata;
                 else if (csr_addr == 12'h341) mepc    <= csr_wdata;
                 else if (csr_addr == 12'h342) mcause  <= csr_wdata;
            end
        end
    end

    assign csr_rdata_internal = (csr_addr == 12'h300) ? mstatus : (csr_addr == 12'h305) ? mtvec : 
                                (csr_addr == 12'h341) ? mepc : (csr_addr == 12'h342) ? mcause : 
                                (csr_addr == 12'hB00 || csr_addr == 12'hC00 || csr_addr == 12'hC01) ? mcycle_counter[31:0] : 
                                (csr_addr == 12'hB80 || csr_addr == 12'hC80 || csr_addr == 12'hC81) ? mcycle_counter[63:32] : 
                                (csr_addr == 12'hF11) ? 32'h79737978 : (csr_addr == 12'hF12) ? 32'd100022721 : 32'b0;

    // MMIO 防打扰机制（DiffTest）
    wire is_mmio = is_mem_inst && (in_uart || in_spi || in_ps2 || in_flash || in_clint || in_sdram);
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

    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg || is_csr);
    wire [31:0] rf_wdata = (is_csr) ? csr_rdata_internal : (op_jal || op_jalr) ? snpc : (op_load) ? ext_mem_rdata : alu_result; 

    regfile u_regfile (.clk(clk), .rst(rst), .wen(rf_wen && !stall && !access_fault), .waddr(rd_idx), .wdata(rf_wdata), .raddr1(rs1_idx), .raddr2(rs2_idx), .rdata1(rs1_data), .rdata2(rs2_data), .a0_val(a0_val));

    export "DPI-C" function npc_read_gpr; function int npc_read_gpr(input int idx); return u_regfile.rf[idx]; endfunction
    export "DPI-C" function npc_read_pc;  function int npc_read_pc; return pc; endfunction

    reg commit_flag; always @(posedge clk) if (rst) commit_flag <= 0; else commit_flag <= !stall; 
    export "DPI-C" function npc_is_commit; function int npc_is_commit; return commit_flag ? 32'd1 : 32'd0; endfunction

    always @(posedge clk) begin
        if (!rst && !stall) begin
            if (is_ebreak) npc_trap(a0_val); 
            npc_itrace_commit(pc, inst, dnpc);
        end
    end
endmodule

// =======================================================================
// 保留的仲裁器模块 (axi_arbiter)
// =======================================================================
module axi_arbiter(
    input wire clk, input wire rst,
    input  wire        ifu_arvalid, output wire        ifu_arready, input  wire [31:0] ifu_araddr, output wire        ifu_rvalid,  input  wire        ifu_rready,  output wire [31:0] ifu_rdata,
    input  wire        lsu_arvalid, output wire        lsu_arready, input  wire [31:0] lsu_araddr, output wire        lsu_rvalid,  input  wire        lsu_rready,  output wire [31:0] lsu_rdata,
    input  wire        lsu_awvalid, output wire        lsu_awready, input  wire [31:0] lsu_awaddr, input  wire        lsu_wvalid,  output wire        lsu_wready,  input  wire [31:0] lsu_wdata, input  wire [3:0]  lsu_wstrb, output wire        lsu_bvalid,  input  wire        lsu_bready,
    output wire        mem_arvalid, input  wire        mem_arready, output wire [31:0] mem_araddr, input  wire        mem_rvalid,  output wire        mem_rready,  input  wire [31:0] mem_rdata,
    output wire        mem_awvalid, input  wire        mem_awready, output wire [31:0] mem_awaddr, output wire        mem_wvalid,  input  wire        mem_wready,  output wire [31:0] mem_wdata, output wire [3:0]  mem_wstrb, input  wire        mem_bvalid,  output wire        mem_bready
);
    assign mem_awvalid = lsu_awvalid; assign lsu_awready = mem_awready; assign mem_awaddr  = lsu_awaddr;
    assign mem_wvalid  = lsu_wvalid;  assign lsu_wready  = mem_wready;  assign mem_wdata   = lsu_wdata; assign mem_wstrb = lsu_wstrb;
    assign lsu_bvalid  = mem_bvalid;  assign mem_bready  = lsu_bready;
    localparam IDLE = 2'b00, GRANT_LSU = 2'b01, GRANT_IFU = 2'b10; reg [1:0] state;
    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else case (state)
            IDLE:      if (lsu_arvalid) state <= GRANT_LSU; else if (ifu_arvalid) state <= GRANT_IFU;
            GRANT_LSU: if (mem_rvalid && mem_rready) state <= IDLE;
            GRANT_IFU: if (mem_rvalid && mem_rready) state <= IDLE;
            default:   state <= IDLE;
        endcase
    end
    assign mem_arvalid = (state == GRANT_LSU) ? lsu_arvalid : (state == GRANT_IFU) ? ifu_arvalid : 1'b0;
    assign mem_araddr  = (state == GRANT_LSU) ? lsu_araddr  : (state == GRANT_IFU) ? ifu_araddr  : 32'b0;
    assign lsu_arready = (state == GRANT_LSU) ? mem_arready : 1'b0; assign ifu_arready = (state == GRANT_IFU) ? mem_arready : 1'b0;
    assign mem_rready  = (state == GRANT_LSU) ? lsu_rready : (state == GRANT_IFU) ? ifu_rready : 1'b0;
    assign lsu_rvalid  = (state == GRANT_LSU) ? mem_rvalid : 1'b0; assign ifu_rvalid  = (state == GRANT_IFU) ? mem_rvalid : 1'b0;
    assign lsu_rdata   = mem_rdata; assign ifu_rdata = mem_rdata;
endmodule

// =======================================================================
// 重获新生的内部计时器 (axi_clint)
// =======================================================================
module axi_clint(
    input clk, input rst,
    input  wire        arvalid, output wire        arready, input  wire [31:0] araddr, output wire        rvalid,  input  wire        rready,  output wire [31:0] rdata,
    input  wire        awvalid, output wire        awready, input  wire [31:0] awaddr, input  wire        wvalid,  output wire        wready,  input  wire [31:0] wdata, input wire [3:0] wstrb, output wire        bvalid,  input  wire        bready
);
    reg [63:0] mtime; always @(posedge clk) begin if (rst) mtime <= 64'b0; else mtime <= mtime + 64'd1; end

    reg rvalid_reg; reg [31:0] rdata_reg;
    always @(posedge clk) begin
         if (rst) begin rvalid_reg <= 0; rdata_reg <= 0; end
         else if (arvalid && !rvalid_reg) begin
             rvalid_reg <= 1;
             if (araddr[7:0] == 8'h48 || araddr[7:0] == 8'hF8) rdata_reg <= mtime[31:0];  
             else if (araddr[7:0] == 8'h4C || araddr[7:0] == 8'hFC) rdata_reg <= mtime[63:32]; 
             else rdata_reg <= 32'h0;
         end else if (rvalid_reg && rready) rvalid_reg <= 0;
    end
    assign arready = !rvalid_reg; assign rvalid = rvalid_reg; assign rdata = rdata_reg;

    reg bvalid_reg;
    always @(posedge clk) begin
         if (rst) bvalid_reg <= 0;
         else if (awvalid && wvalid && !bvalid_reg) begin bvalid_reg <= 1; end
         else if (bvalid_reg && bready) bvalid_reg <= 0;
    end
    assign awready = !bvalid_reg; assign wready = !bvalid_reg; assign bvalid = bvalid_reg;
endmodule
