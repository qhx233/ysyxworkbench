/*
module example(
    input  wire        clk,
    input  wire        rst,
    output reg  [31:0] pc
);
    wire [31:0] rs1_data;
    wire [31:0] rs2_data;
    wire [31:0] alu_result;
    wire [31:0] a0_val; 

    //===========================================================================
    // DPI-C Interfaces
    //===========================================================================
    import "DPI-C" function void npc_trap(input int a0_val);
    import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);
    import "DPI-C" function int  pmem_read(input int raddr);
    import "DPI-C" function void npc_itrace_commit(input int pc, input int inst, input int dnpc);

    //===========================================================================
    // 0. LFSR 伪随机数发生器 (16-bit)
    //===========================================================================
    reg [15:0] lfsr;
    always @(posedge clk) begin
        if (rst) begin
            lfsr <= 16'hACE1; // 种子绝对不能为 0
        end else begin
            // 经典的 Fibonacci LFSR 多项式
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    end

    //===========================================================================
    // 状态机定义
    //===========================================================================
    localparam IF_IDLE  = 2'b00;
    localparam IF_WAIT  = 2'b01;
    localparam MEM_WAIT = 2'b10;
    reg [1:0] state;

    //===========================================================================
    // 1. IFU (Instruction Fetch) - 带有随机延迟的真实握手模型
    //===========================================================================
    // Master: 只有在 IF_IDLE 状态，且随机数允许（50%概率）时才发出请求
    wire ifu_reqValid = (state == IF_IDLE) && lfsr[0]; 

    // Slave: 带有随机倒计时的存储器
    reg        ifu_respValid_reg;
    reg        ifu_mem_busy;
    reg [3:0]  ifu_delay_cnt;
    reg [31:0] ifu_rdata_reg;

    always @(posedge clk) begin
        if (rst) begin
            ifu_respValid_reg <= 1'b0;
            ifu_mem_busy      <= 1'b0;
            ifu_delay_cnt     <= 4'b0;
            ifu_rdata_reg     <= 32'b0;
        end else begin
            ifu_respValid_reg <= 1'b0; // 默认拉低，只像脉冲一样高一拍
            
            if (ifu_reqValid && !ifu_mem_busy) begin
                ifu_mem_busy  <= 1'b1;
                ifu_delay_cnt <= lfsr[4:1]; // 随机延迟 0~15 拍
            end else if (ifu_mem_busy) begin
                if (ifu_delay_cnt == 4'b0) begin
                    ifu_mem_busy      <= 1'b0;
                    ifu_respValid_reg <= 1'b1;         // 倒计时结束，发出响应
                    ifu_rdata_reg     <= pmem_read(pc); // 读取指令
                end else begin
                    ifu_delay_cnt <= ifu_delay_cnt - 1'b1;
                end
            end
        end
    end

    wire ifu_respValid = ifu_respValid_reg;
    wire [31:0] ifu_rdata = ifu_rdata_reg;

    // --- 指令锁存器 ---
    reg [31:0] inst_reg;
    always @(posedge clk) begin
        if (rst) inst_reg <= 32'h0;
        else if (state == IF_WAIT && ifu_respValid) inst_reg <= ifu_rdata;
    end

    wire [31:0] inst = (state == IF_WAIT && ifu_respValid) ? ifu_rdata : 
                       (state == MEM_WAIT)                 ? inst_reg : 
                       32'h00000013; 

    //===========================================================================
    // 译码前置信号
    //===========================================================================
    wire [6:0] opcode = inst[6:0];
    wire op_load  = (opcode == 7'b0000011);
    wire op_store = (opcode == 7'b0100011);
    wire is_mem_inst = op_load || op_store;

    //===========================================================================
    // 2. LSU (Load/Store Unit) - 带有随机延迟的真实握手模型
    //===========================================================================
    wire [31:0] mem_addr   = alu_result & ~32'h3; 
    wire [1:0]  mem_offset = alu_result[1:0];
    wire lsu_wen = op_store; 
    wire lsu_ren = op_load;

    // Master: 必须确保在一个指令生命周期内，只发出一次请求
    reg lsu_req_sent;
    always @(posedge clk) begin
        if (rst) lsu_req_sent <= 1'b0;
        else if (state == IF_IDLE) lsu_req_sent <= 1'b0; // 每一条新指令开始前复位
        else if (lsu_reqValid)     lsu_req_sent <= 1'b1; // 发出后锁死
    end
    
    // 只有在 MEM_WAIT 状态，尚未发送过，且随机数允许时，才发请求
    wire lsu_reqValid = (state == MEM_WAIT) && !lsu_req_sent && lfsr[5];

    // Slave: 带有随机倒计时的存储器
    reg        lsu_respValid_reg;
    reg        lsu_mem_busy;
    reg [3:0]  lsu_delay_cnt;
    reg [31:0] lsu_rdata_reg;

    wire [7:0] wmask = 
        (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : 
        (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : 
        (funct3 == 3'b010) ? 8'b0000_1111                 : 8'b0;

    wire [31:0] wdata = 
        (funct3 == 3'b000) ? {4{rs2_data[7:0]}}  : 
        (funct3 == 3'b001) ? {2{rs2_data[15:0]}} : rs2_data; 

    always @(posedge clk) begin
        if (rst) begin
            lsu_respValid_reg <= 1'b0;
            lsu_mem_busy      <= 1'b0;
            lsu_delay_cnt     <= 4'b0;
            lsu_rdata_reg     <= 32'b0;
        end else begin
            lsu_respValid_reg <= 1'b0;
            
            if (lsu_reqValid && !lsu_mem_busy) begin
                lsu_mem_busy  <= 1'b1;
                lsu_delay_cnt <= lfsr[9:6]; // 随机延迟 0~15 拍
            end else if (lsu_mem_busy) begin
                if (lsu_delay_cnt == 4'b0) begin
                    lsu_mem_busy      <= 1'b0;
                    lsu_respValid_reg <= 1'b1; // 倒计时结束
                    if (lsu_ren) lsu_rdata_reg <= pmem_read(mem_addr);
                    if (lsu_wen) pmem_write(mem_addr, wdata, wmask);
                end else begin
                    lsu_delay_cnt <= lsu_delay_cnt - 1'b1;
                end
            end
        end
    end
    wire lsu_respValid = lsu_respValid_reg;
    wire [31:0] lsu_rdata = lsu_rdata_reg;

    wire [7:0] byte_data = (mem_offset == 2'b00) ? lsu_rdata[7:0]   :
                           (mem_offset == 2'b01) ? lsu_rdata[15:8]  :
                           (mem_offset == 2'b10) ? lsu_rdata[23:16] : lsu_rdata[31:24];
    wire [15:0] half_data = (mem_offset[1] == 1'b0) ? lsu_rdata[15:0] : lsu_rdata[31:16];

    wire [31:0] mem_rdata = 
        (funct3 == 3'b000) ? {{24{byte_data[7]}}, byte_data}   : 
        (funct3 == 3'b001) ? {{16{half_data[15]}}, half_data}  : 
        (funct3 == 3'b010) ? lsu_rdata                         : 
        (funct3 == 3'b100) ? {24'b0, byte_data}                : 
        (funct3 == 3'b101) ? {16'b0, half_data}                : 32'b0;

    //===========================================================================
    // 动态状态机跃迁 (严格遵守握手定律)
    //===========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state <= IF_IDLE;
        end else begin
            case (state)
                IF_IDLE: begin
                    // 只有真正把请求发出去了，才进入等待数据状态
                    if (ifu_reqValid) state <= IF_WAIT; 
                end
                IF_WAIT: begin
                    if (ifu_respValid) begin
                        if (is_mem_inst) state <= MEM_WAIT;
                        else             state <= IF_IDLE;
                    end
                end
                MEM_WAIT: begin
                    if (lsu_respValid) state <= IF_IDLE;
                end
                default: state <= IF_IDLE;
            endcase
        end
    end

    // --- 极其精准的 Stall 逻辑 ---
    wire commit_if_wait  = (state == IF_WAIT) && ifu_respValid && !is_mem_inst;
    wire commit_mem_wait = (state == MEM_WAIT) && lsu_respValid;
    wire stall = !(commit_if_wait || commit_mem_wait);

    //===========================================================================
    // IDU & EXU
    //===========================================================================
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    wire [4:0] rs1_idx = inst[19:15];
    wire [4:0] rs2_idx = inst[24:20];
    wire [4:0] rd_idx  = inst[11:7];

    wire [31:0] imm_I = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_S = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_B = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_U = {inst[31:12], 12'b0};
    wire [31:0] imm_J = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};

    wire op_lui    = (opcode == 7'b0110111);
    wire op_auipc  = (opcode == 7'b0010111);
    wire op_jal    = (opcode == 7'b1101111);
    wire op_jalr   = (opcode == 7'b1100111);
    wire op_branch = (opcode == 7'b1100011);
    wire op_imm    = (opcode == 7'b0010011);
    wire op_reg    = (opcode == 7'b0110011);
    wire op_system = (opcode == 7'b1110011); 
    
    wire is_ebreak = (inst == 32'h00100073);
    wire [11:0] csr_addr = inst[31:20];               

    wire is_ecall = op_system && (funct3 == 3'b000) && (csr_addr == 12'b0000_0000_0000);
    wire is_mret  = op_system && (funct3 == 3'b000) && (csr_addr == 12'b0011_0000_0010);
    wire is_csr   = op_system && (funct3 != 3'b000); 
    wire is_csrrw = is_csr && (funct3 == 3'b001);
    wire is_csrrs = is_csr && (funct3 == 3'b010);

    wire alu_eq  = (rs1_data == rs2_data);
    wire alu_lt  = ($signed(rs1_data) < $signed(rs2_data));
    wire alu_ltu = (rs1_data < rs2_data);

    wire branch_taken = op_branch && (
        (funct3 == 3'b000 &&  alu_eq) || 
        (funct3 == 3'b001 && !alu_eq) || 
        (funct3 == 3'b100 &&  alu_lt) || 
        (funct3 == 3'b101 && !alu_lt) || 
        (funct3 == 3'b110 &&  alu_ltu)|| 
        (funct3 == 3'b111 && !alu_ltu)   
    );

    wire [31:0] snpc = pc + 32'h4;
    wire [31:0] csr_mtvec; 
    wire [31:0] csr_mepc;

    wire [31:0] dnpc = (is_ecall)     ? csr_mtvec :              
                       (is_mret)      ? csr_mepc :               
                       (op_jal)       ? (pc + imm_J) :
                       (op_jalr)      ? ((rs1_data + imm_I) & ~32'h1) :
                       (branch_taken) ? (pc + imm_B) : snpc;

    always @(posedge clk) begin
        if (rst) pc <= 32'h80000000;
        else if (!stall) pc <= dnpc;
    end

    wire is_sub = (op_reg && funct7[5]) || op_branch; 
    wire is_sra = (funct7[5] && (op_reg || op_imm) && funct3 == 3'b101);
    wire [3:0] alu_op = (op_lui || op_auipc || op_jal || op_load || op_store) ? 4'b0000 : 
                        { (is_sub || is_sra), funct3 };

    wire [31:0] alu_src1 = (op_auipc) ? pc :
                           (op_lui)   ? 32'b0 : rs1_data;

    wire [31:0] alu_src2 = (op_imm || op_load || op_jalr) ? imm_I :
                           (op_store)                     ? imm_S :
                           (op_lui || op_auipc)           ? imm_U : rs2_data;

    alu u_alu (
        .src1(alu_src1),
        .src2(alu_src2),
        .alu_op(alu_op),
        .result(alu_result)
    ); 

    //===========================================================================
    // CSR & WBU
    //===========================================================================
    reg [63:0] mcycle_counter;
    always @(posedge clk) begin
        if (rst) mcycle_counter <= 64'b0;
        else     mcycle_counter <= mcycle_counter + 64'b1; 
    end

    reg [31:0] mstatus, mtvec, mepc, mcause;  

    assign csr_mtvec = mtvec;
    assign csr_mepc  = mepc;

    wire csr_wen = (is_csrrw) || (is_csrrs && rs1_idx != 0);
    wire [31:0] csr_rdata_internal;
    wire [31:0] csr_wdata = (is_csrrw) ? rs1_data :
                            (is_csrrs) ? (csr_rdata_internal | rs1_data) : 32'b0;

    always @(posedge clk) begin
        if (rst) begin
            mstatus <= 32'h1800; mtvec <= 32'b0; mepc <= 32'b0; mcause <= 32'b0;
        end else if (!stall) begin
            if (is_ecall) begin
                mepc <= pc; mcause <= 32'd11;    
            end else if (csr_wen) begin
                 if      (csr_addr == 12'h300) mstatus <= csr_wdata;
                 else if (csr_addr == 12'h305) mtvec   <= csr_wdata;
                 else if (csr_addr == 12'h341) mepc    <= csr_wdata;
                 else if (csr_addr == 12'h342) mcause  <= csr_wdata;
            end
        end
    end

    assign csr_rdata_internal = 
        (csr_addr == 12'h300) ? mstatus : (csr_addr == 12'h305) ? mtvec   :
        (csr_addr == 12'h341) ? mepc    : (csr_addr == 12'h342) ? mcause  :
        (csr_addr == 12'hB00) ? mcycle_counter[31:0]  : 
        (csr_addr == 12'hB80) ? mcycle_counter[63:32] : 
        (csr_addr == 12'hF11) ? 32'h79737978          : 
        (csr_addr == 12'hF12) ? 32'd100022721         : 32'b0;

    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg || is_csr);
    wire [31:0] rf_wdata = (is_csr)            ? csr_rdata_internal :
                           (op_jal || op_jalr) ? snpc               :
                           (op_load)           ? mem_rdata          : alu_result; 

    regfile u_regfile (
        .clk(clk), .rst(rst),
        .wen(rf_wen && !stall),
        .waddr(rd_idx), .wdata(rf_wdata),
        .raddr1(rs1_idx), .raddr2(rs2_idx),
        .rdata1(rs1_data), .rdata2(rs2_data),
        .a0_val(a0_val) 
    );

    export "DPI-C" function npc_read_gpr;
    function int npc_read_gpr(input int idx); return u_regfile.rf[idx]; endfunction

    export "DPI-C" function npc_read_pc;
    function int npc_read_pc; return pc; endfunction

    reg commit_flag;
    always @(posedge clk) begin
        if (rst) commit_flag <= 1'b0;
        else     commit_flag <= !stall; 
    end

    export "DPI-C" function npc_is_commit;
    function int npc_is_commit; return commit_flag ? 32'd1 : 32'd0; endfunction

    always @(posedge clk) begin
        if (!rst && !stall) begin
            if (is_ebreak) npc_trap(a0_val); 
            npc_itrace_commit(pc, inst, dnpc);
        end
    end

endmodule*/


/*module example(
    input  wire        clk,
    input  wire        rst,
    output reg  [31:0] pc
);
    wire [31:0] rs1_data;
    wire [31:0] rs2_data;
    wire [31:0] alu_result;
    wire [31:0] a0_val; 

    //===========================================================================
    // DPI-C Interfaces
    //===========================================================================
    import "DPI-C" function void npc_trap(input int a0_val);
    import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);
    import "DPI-C" function int  pmem_read(input int raddr);
    import "DPI-C" function void npc_itrace_commit(input int pc, input int inst, input int dnpc);

    //===========================================================================
    // 0. LFSR 伪随机数发生器
    //===========================================================================
    reg [15:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    //===========================================================================
    // 1. 核心总线状态机定义
    //===========================================================================
    localparam ST_IF_REQ  = 2'b00;
    localparam ST_IF_RSP  = 2'b01;
    localparam ST_MEM_REQ = 2'b10;
    localparam ST_MEM_RSP = 2'b11;
    reg [1:0] state;

    //===========================================================================
    // 2. 双路 AXI4-Lite 接口声明 (Master 视角)
    //===========================================================================
    // --- IFU 接口 (指令抓取) ---
    wire        ifu_arvalid;
    wire        ifu_arready;
    wire [31:0] ifu_araddr;
    wire        ifu_rvalid;
    wire        ifu_rready;
    wire [31:0] ifu_rdata;
    
    // IFU 严格遵循只读约束，强行将写通道置零
    wire        ifu_awvalid = 1'b0;
    wire [31:0] ifu_awaddr  = 32'b0;
    wire        ifu_wvalid  = 1'b0;
    wire [31:0] ifu_wdata   = 32'b0;
    wire [3:0]  ifu_wstrb   = 4'b0;
    wire        ifu_bready  = 1'b0;

    // --- LSU 接口 (数据访存) ---
    wire        lsu_arvalid;
    wire        lsu_arready;
    wire [31:0] lsu_araddr;
    wire        lsu_rvalid;
    wire        lsu_rready;
    wire [31:0] lsu_rdata;

    wire        lsu_awvalid;
    wire        lsu_awready;
    wire [31:0] lsu_awaddr;
    wire        lsu_wvalid;
    wire        lsu_wready;
    wire [31:0] lsu_wdata;
    wire [3:0]  lsu_wstrb;
    wire        lsu_bvalid;
    wire        lsu_bready;

    // 握手成功标志
    wire ifu_hsk_ar = ifu_arvalid && ifu_arready;
    wire ifu_hsk_r  = ifu_rvalid  && ifu_rready;
    
    wire lsu_hsk_ar = lsu_arvalid && lsu_arready;
    wire lsu_hsk_r  = lsu_rvalid  && lsu_rready;
    wire lsu_hsk_aw = lsu_awvalid && lsu_awready;
    wire lsu_hsk_w  = lsu_wvalid  && lsu_wready;
    wire lsu_hsk_b  = lsu_bvalid  && lsu_bready;

    //===========================================================================
    // 3. 译码与指令锁存
    //===========================================================================
    reg [31:0] inst_reg;
    always @(posedge clk) begin
        if (rst)               inst_reg <= 32'h00000013; // NOP
        else if (ifu_hsk_r)    inst_reg <= ifu_rdata;
    end
    
    wire [31:0] inst = (state == ST_IF_RSP && ifu_hsk_r) ? ifu_rdata : inst_reg;

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    wire op_load  = (opcode == 7'b0000011);
    wire op_store = (opcode == 7'b0100011);
    wire is_mem_inst = op_load || op_store;

    wire [31:0] mem_addr   = alu_result & ~32'h3; 
    wire [1:0]  mem_offset = alu_result[1:0];
    wire [7:0] wmask = (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : 
                       (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : 
                       (funct3 == 3'b010) ? 8'b0000_1111 : 8'b0;
    wire [31:0] wdata = (funct3 == 3'b000) ? {4{rs2_data[7:0]}}  : 
                        (funct3 == 3'b001) ? {2{rs2_data[15:0]}} : rs2_data; 

    //===========================================================================
    // 4. 核心状态机与并发写通道握手记录
    //===========================================================================
    reg aw_done, w_done;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IF_REQ;
            aw_done <= 1'b0; w_done <= 1'b0;
        end else begin
            case (state)
                ST_IF_REQ: begin
                    if (ifu_hsk_ar) state <= ST_IF_RSP;
                end
                ST_IF_RSP: begin
                    if (ifu_hsk_r) state <= is_mem_inst ? ST_MEM_REQ : ST_IF_REQ;
                end
                ST_MEM_REQ: begin
                    if (op_load) begin
                        if (lsu_hsk_ar) state <= ST_MEM_RSP;
                    end else if (op_store) begin
                        // 独立记录写地址和写数据的并发握手情况
                        if (lsu_hsk_aw) aw_done <= 1'b1;
                        if (lsu_hsk_w)  w_done  <= 1'b1;
                        if ((aw_done || lsu_hsk_aw) && (w_done || lsu_hsk_w)) begin
                            state   <= ST_MEM_RSP;
                            aw_done <= 1'b0; w_done  <= 1'b0;
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

    // 流水线 Stall 逻辑
    wire commit_non_mem = (state == ST_IF_RSP)  && ifu_hsk_r && !is_mem_inst;
    wire commit_mem     = (state == ST_MEM_RSP) && (op_load ? lsu_hsk_r : lsu_hsk_b);
    wire stall = !(commit_non_mem || commit_mem);

    //===========================================================================
    // 5. AXI4-Lite Master 信号驱动 (严格符合握手铁律)
    //===========================================================================
    assign ifu_arvalid = (state == ST_IF_REQ);
    assign ifu_araddr  = pc;
    assign ifu_rready  = (state == ST_IF_RSP);

    assign lsu_arvalid = (state == ST_MEM_REQ) && op_load;
    assign lsu_araddr  = mem_addr;
    assign lsu_rready  = (state == ST_MEM_RSP) && op_load;

    // 写请求的 Valid 信号在当前周期尚未完成握手时一直保持为高
    assign lsu_awvalid = (state == ST_MEM_REQ) && op_store && !aw_done;
    assign lsu_awaddr  = mem_addr;
    assign lsu_wvalid  = (state == ST_MEM_REQ) && op_store && !w_done;
    assign lsu_wdata   = wdata;
    assign lsu_wstrb   = wmask[3:0];
    assign lsu_bready  = (state == ST_MEM_RSP) && op_store;

    //===========================================================================
    // 6. 执行单元 (EXU) 
    //===========================================================================
    wire [4:0] rs1_idx = inst[19:15];
    wire [4:0] rs2_idx = inst[24:20];
    wire [4:0] rd_idx  = inst[11:7];

    wire [31:0] imm_I = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_S = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_B = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_U = {inst[31:12], 12'b0};
    wire [31:0] imm_J = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};

    wire op_lui    = (opcode == 7'b0110111);
    wire op_auipc  = (opcode == 7'b0010111);
    wire op_jal    = (opcode == 7'b1101111);
    wire op_jalr   = (opcode == 7'b1100111);
    wire op_branch = (opcode == 7'b1100011);
    wire op_imm    = (opcode == 7'b0010011);
    wire op_reg    = (opcode == 7'b0110011);
    wire op_system = (opcode == 7'b1110011); 
    wire is_ebreak = (inst == 32'h00100073);

    wire alu_eq  = (rs1_data == rs2_data);
    wire alu_lt  = ($signed(rs1_data) < $signed(rs2_data));
    wire alu_ltu = (rs1_data < rs2_data);

    wire branch_taken = op_branch && (
        (funct3 == 3'b000 &&  alu_eq)  || (funct3 == 3'b001 && !alu_eq) || 
        (funct3 == 3'b100 &&  alu_lt)  || (funct3 == 3'b101 && !alu_lt) || 
        (funct3 == 3'b110 &&  alu_ltu) || (funct3 == 3'b111 && !alu_ltu)   
    );

    wire [31:0] snpc = pc + 32'h4;
    wire [31:0] csr_mtvec, csr_mepc;
    wire is_ecall = op_system && (funct3 == 3'b000) && (inst[31:20] == 12'b0);
    wire is_mret  = op_system && (funct3 == 3'b000) && (inst[31:20] == 12'b001100000010);

    wire [31:0] dnpc = (is_ecall)     ? csr_mtvec :              
                       (is_mret)      ? csr_mepc :               
                       (op_jal)       ? (pc + imm_J) :
                       (op_jalr)      ? ((rs1_data + imm_I) & ~32'h1) :
                       (branch_taken) ? (pc + imm_B) : snpc;

    always @(posedge clk) begin
        if (rst)         pc <= 32'h80000000;
        else if (!stall) pc <= dnpc;
    end

    wire is_sub = (op_reg && funct7[5]) || op_branch; 
    wire is_sra = (funct7[5] && (op_reg || op_imm) && funct3 == 3'b101);
    wire [3:0] alu_op = (op_lui || op_auipc || op_jal || op_load || op_store) ? 4'b0000 : { (is_sub || is_sra), funct3 };
    wire [31:0] alu_src1 = (op_auipc) ? pc : (op_lui) ? 32'b0 : rs1_data;
    wire [31:0] alu_src2 = (op_imm || op_load || op_jalr) ? imm_I : (op_store) ? imm_S : (op_lui || op_auipc) ? imm_U : rs2_data;

    alu u_alu (.src1(alu_src1), .src2(alu_src2), .alu_op(alu_op), .result(alu_result)); 

    //===========================================================================
    // 7. AXI4-Lite 双端口模拟内存 (Slave 端) - 包含随机延迟
    //===========================================================================
    
    // --- IFU 存储器通道模拟 ---
    reg ifu_ar_busy;
    reg [3:0] ifu_ar_delay;
    reg [31:0] ifu_rdata_reg;
    reg ifu_rvalid_reg;

    assign ifu_arready = !ifu_ar_busy && lfsr[1];
    assign ifu_rvalid  = ifu_rvalid_reg;
    assign ifu_rdata   = ifu_rdata_reg;

    always @(posedge clk) begin
        if (rst) begin
            ifu_ar_busy <= 1'b0; ifu_ar_delay <= 4'b0; ifu_rvalid_reg <= 1'b0;
        end else begin
            if (ifu_hsk_ar) begin
                ifu_ar_busy  <= 1'b1;
                ifu_ar_delay <= lfsr[3:0]; 
            end else if (ifu_ar_busy) begin
                if (ifu_ar_delay == 0) begin
                    ifu_ar_busy <= 1'b0;
                    ifu_rvalid_reg <= 1'b1;
                    ifu_rdata_reg <= pmem_read(ifu_araddr);
                end else begin
                    ifu_ar_delay <= ifu_ar_delay - 1'b1;
                end
            end else if (ifu_hsk_r) begin
                ifu_rvalid_reg <= 1'b0;
            end
        end
    end

    // --- LSU 存储器通道模拟 ---
    // LSU Read Channel
    reg lsu_ar_busy;
    reg [3:0] lsu_ar_delay;
    reg [31:0] lsu_rdata_reg;
    reg lsu_rvalid_reg;

    assign lsu_arready = !lsu_ar_busy && lfsr[4];
    assign lsu_rvalid  = lsu_rvalid_reg;
    assign lsu_rdata   = lsu_rdata_reg;

    always @(posedge clk) begin
        if (rst) begin
            lsu_ar_busy <= 1'b0; lsu_ar_delay <= 4'b0; lsu_rvalid_reg <= 1'b0;
        end else begin
            if (lsu_hsk_ar) begin
                lsu_ar_busy  <= 1'b1;
                lsu_ar_delay <= lfsr[7:4];
            end else if (lsu_ar_busy) begin
                if (lsu_ar_delay == 0) begin
                    lsu_ar_busy <= 1'b0;
                    lsu_rvalid_reg <= 1'b1;
                    lsu_rdata_reg <= pmem_read(lsu_araddr);
                end else begin
                    lsu_ar_delay <= lsu_ar_delay - 1'b1;
                end
            end else if (lsu_hsk_r) begin
                lsu_rvalid_reg <= 1'b0;
            end
        end
    end

    // LSU Write Channel
    reg lsu_aw_busy, lsu_w_busy;
    reg [31:0] mem_write_addr_reg;
    reg [31:0] mem_write_data_reg;
    reg [3:0]  mem_write_strb_reg;
    reg lsu_bvalid_reg;

    assign lsu_awready = !lsu_aw_busy && lfsr[8];
    assign lsu_wready  = !lsu_w_busy  && lfsr[9];
    assign lsu_bvalid  = lsu_bvalid_reg;

    always @(posedge clk) begin
        if (rst) begin
            lsu_aw_busy <= 1'b0; lsu_w_busy <= 1'b0; lsu_bvalid_reg <= 1'b0;
        end else begin
            if (lsu_hsk_aw) begin lsu_aw_busy <= 1'b1; mem_write_addr_reg <= lsu_awaddr; end
            if (lsu_hsk_w)  begin lsu_w_busy  <= 1'b1; mem_write_data_reg <= lsu_wdata; mem_write_strb_reg <= lsu_wstrb; end
            
            // 两路数据都齐了，且尚未发出过 B 响应信号时，执行写入
            if (lsu_aw_busy && lsu_w_busy && !lsu_bvalid_reg) begin
                pmem_write(mem_write_addr_reg, mem_write_data_reg, {4'b0, mem_write_strb_reg});
                lsu_bvalid_reg <= 1'b1;
            end else if (lsu_hsk_b) begin
                // B 响应被接受，事务彻底结束
                lsu_aw_busy <= 1'b0; lsu_w_busy <= 1'b0; lsu_bvalid_reg <= 1'b0;
            end
        end
    end

    // Load 数据符号扩展截取
    wire [7:0] byte_data = (mem_offset == 2'b00) ? lsu_rdata[7:0]   :
                           (mem_offset == 2'b01) ? lsu_rdata[15:8]  :
                           (mem_offset == 2'b10) ? lsu_rdata[23:16] : lsu_rdata[31:24];
    wire [15:0] half_data = (mem_offset[1] == 1'b0) ? lsu_rdata[15:0] : lsu_rdata[31:16];

    wire [31:0] mem_rdata = 
        (funct3 == 3'b000) ? {{24{byte_data[7]}}, byte_data}   : 
        (funct3 == 3'b001) ? {{16{half_data[15]}}, half_data}  : 
        (funct3 == 3'b010) ? lsu_rdata                         : 
        (funct3 == 3'b100) ? {24'b0, byte_data}                : 
        (funct3 == 3'b101) ? {16'b0, half_data}                : 32'b0;

    //===========================================================================
    // 8. CSR 与 WBU 控制逻辑
    //===========================================================================
    wire is_csr   = op_system && (funct3 != 3'b000); 
    wire is_csrrw = is_csr && (funct3 == 3'b001);
    wire is_csrrs = is_csr && (funct3 == 3'b010);
    wire [11:0] csr_addr = inst[31:20]; 

    reg [63:0] mcycle_counter;
    always @(posedge clk) begin
        if (rst) mcycle_counter <= 64'b0;
        else     mcycle_counter <= mcycle_counter + 64'b1; 
    end

    reg [31:0] mstatus, mtvec, mepc, mcause;  
    assign csr_mtvec = mtvec; assign csr_mepc = mepc;

    wire csr_wen = (is_csrrw) || (is_csrrs && rs1_idx != 0);
    wire [31:0] csr_rdata_internal;
    wire [31:0] csr_wdata = (is_csrrw) ? rs1_data :
                            (is_csrrs) ? (csr_rdata_internal | rs1_data) : 32'b0;

    always @(posedge clk) begin
        if (rst) begin 
            mstatus <= 32'h1800; mtvec <= 32'b0; mepc <= 32'b0; mcause <= 32'b0; 
        end else if (!stall) begin
            if (is_ecall) begin 
                mepc <= pc; mcause <= 32'd11; 
            end else if (csr_wen) begin
                 if      (csr_addr == 12'h300) mstatus <= csr_wdata;
                 else if (csr_addr == 12'h305) mtvec   <= csr_wdata;
                 else if (csr_addr == 12'h341) mepc    <= csr_wdata;
                 else if (csr_addr == 12'h342) mcause  <= csr_wdata;
            end
        end
    end

    assign csr_rdata_internal = 
        (csr_addr == 12'h300) ? mstatus : (csr_addr == 12'h305) ? mtvec   :
        (csr_addr == 12'h341) ? mepc    : (csr_addr == 12'h342) ? mcause  :
        (csr_addr == 12'hB00) ? mcycle_counter[31:0]  : 
        (csr_addr == 12'hB80) ? mcycle_counter[63:32] : 
        (csr_addr == 12'hF11) ? 32'h79737978          : 
        (csr_addr == 12'hF12) ? 32'd100022721         : 32'b0;

    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg || is_csr);
    wire [31:0] rf_wdata = (is_csr)            ? csr_rdata_internal :
                           (op_jal || op_jalr) ? snpc               :
                           (op_load)           ? mem_rdata          : alu_result; 

    regfile u_regfile (
        .clk(clk), .rst(rst), 
        .wen(rf_wen && !stall), 
        .waddr(rd_idx), .wdata(rf_wdata),
        .raddr1(rs1_idx), .raddr2(rs2_idx), .rdata1(rs1_data), .rdata2(rs2_data), 
        .a0_val(a0_val) 
    );

    //===========================================================================
    // 9. C++ 接口暴露
    //===========================================================================
    export "DPI-C" function npc_read_gpr;
    function int npc_read_gpr(input int idx); return u_regfile.rf[idx]; endfunction
    
    export "DPI-C" function npc_read_pc;
    function int npc_read_pc; return pc; endfunction

    reg commit_flag;
    always @(posedge clk) begin
        if (rst) commit_flag <= 1'b0;
        else     commit_flag <= !stall; 
    end
    
    export "DPI-C" function npc_is_commit;
    function int npc_is_commit; return commit_flag ? 32'd1 : 32'd0; endfunction

    always @(posedge clk) begin
        if (!rst && !stall) begin
            if (is_ebreak) npc_trap(a0_val); 
            npc_itrace_commit(pc, inst, dnpc);
        end
    end
endmodule*/
module example(
    input  wire        clk,
    input  wire        rst,
    output reg  [31:0] pc
);
    wire [31:0] rs1_data; wire [31:0] rs2_data;
    wire [31:0] alu_result; wire [31:0] a0_val; 

    import "DPI-C" function void npc_trap(input int a0_val);
    import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);
    import "DPI-C" function int  pmem_read(input int raddr);
    import "DPI-C" function void npc_itrace_commit(input int pc, input int inst, input int dnpc);

    reg [15:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

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

    wire [6:0] opcode = inst[6:0]; wire [2:0] funct3 = inst[14:12]; wire [6:0] funct7 = inst[31:25];
    wire op_load = (opcode == 7'b0000011), op_store = (opcode == 7'b0100011);
    wire is_mem_inst = op_load || op_store;

    wire [31:0] mem_addr   = alu_result & ~32'h3; 
    wire [1:0]  mem_offset = alu_result[1:0];
    wire [7:0] wmask = (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : 
                       (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : 
                       (funct3 == 3'b010) ? 8'b0000_1111 : 8'b0;
    wire [31:0] wdata = (funct3 == 3'b000) ? {4{rs2_data[7:0]}}  : 
                        (funct3 == 3'b001) ? {2{rs2_data[15:0]}} : rs2_data; 

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
    assign lsu_arvalid = (state == ST_MEM_REQ) && op_load; assign lsu_araddr  = mem_addr; assign lsu_rready  = (state == ST_MEM_RSP) && op_load;
    assign lsu_awvalid = (state == ST_MEM_REQ) && op_store && !aw_done; assign lsu_awaddr  = mem_addr;
    assign lsu_wvalid  = (state == ST_MEM_REQ) && op_store && !w_done; assign lsu_wdata   = wdata; assign lsu_wstrb   = wmask[3:0];
    assign lsu_bready  = (state == ST_MEM_RSP) && op_store;

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

    always @(posedge clk) begin if (rst) pc <= 32'h80000000; else if (!stall) pc <= dnpc; end

    wire is_sub = (op_reg && funct7[5]) || op_branch; wire is_sra = (funct7[5] && (op_reg || op_imm) && funct3 == 3'b101);
    wire [3:0] alu_op = (op_lui || op_auipc || op_jal || op_load || op_store) ? 4'b0000 : { (is_sub || is_sra), funct3 };
    wire [31:0] alu_src1 = (op_auipc) ? pc : (op_lui) ? 32'b0 : rs1_data;
    wire [31:0] alu_src2 = (op_imm || op_load || op_jalr) ? imm_I : (op_store) ? imm_S : (op_lui || op_auipc) ? imm_U : rs2_data;
    alu u_alu (.src1(alu_src1), .src2(alu_src2), .alu_op(alu_op), .result(alu_result)); 

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

    wire        sram_arvalid, sram_arready; wire [31:0] sram_araddr;
    wire        sram_rvalid,  sram_rready;  wire [31:0] sram_rdata;
    wire        sram_awvalid, sram_awready; wire [31:0] sram_awaddr;
    wire        sram_wvalid,  sram_wready;  wire [31:0] sram_wdata; wire [3:0] sram_wstrb;
    wire        sram_bvalid,  sram_bready;

    wire        uart_arvalid, uart_arready; wire [31:0] uart_araddr;
    wire        uart_rvalid,  uart_rready;  wire [31:0] uart_rdata;
    wire        uart_awvalid, uart_awready; wire [31:0] uart_awaddr;
    wire        uart_wvalid,  uart_wready;  wire [31:0] uart_wdata; wire [3:0] uart_wstrb;
    wire        uart_bvalid,  uart_bready;

    wire        clint_arvalid, clint_arready; wire [31:0] clint_araddr;
    wire        clint_rvalid,  clint_rready;  wire [31:0] clint_rdata;
    wire        clint_awvalid, clint_awready; wire [31:0] clint_awaddr;
    wire        clint_wvalid,  clint_wready;  wire [31:0] clint_wdata; wire [3:0] clint_wstrb;
    wire        clint_bvalid,  clint_bready;

    axi_xbar_1to3 u_xbar (
        .clk(clk), .rst(rst),
        .m_arvalid(arb_arvalid), .m_arready(arb_arready), .m_araddr(arb_araddr), .m_rvalid(arb_rvalid), .m_rready(arb_rready), .m_rdata(arb_rdata),
        .m_awvalid(arb_awvalid), .m_awready(arb_awready), .m_awaddr(arb_awaddr), .m_wvalid(arb_wvalid), .m_wready(arb_wready), .m_wdata(arb_wdata), .m_wstrb(arb_wstrb), .m_bvalid(arb_bvalid), .m_bready(arb_bready),
        .s0_arvalid(sram_arvalid), .s0_arready(sram_arready), .s0_araddr(sram_araddr), .s0_rvalid(sram_rvalid), .s0_rready(sram_rready), .s0_rdata(sram_rdata),
        .s0_awvalid(sram_awvalid), .s0_awready(sram_awready), .s0_awaddr(sram_awaddr), .s0_wvalid(sram_wvalid), .s0_wready(sram_wready), .s0_wdata(sram_wdata), .s0_wstrb(sram_wstrb), .s0_bvalid(sram_bvalid), .s0_bready(sram_bready),
        .s1_arvalid(uart_arvalid), .s1_arready(uart_arready), .s1_araddr(uart_araddr), .s1_rvalid(uart_rvalid), .s1_rready(uart_rready), .s1_rdata(uart_rdata),
        .s1_awvalid(uart_awvalid), .s1_awready(uart_awready), .s1_awaddr(uart_awaddr), .s1_wvalid(uart_wvalid), .s1_wready(uart_wready), .s1_wdata(uart_wdata), .s1_wstrb(uart_wstrb), .s1_bvalid(uart_bvalid), .s1_bready(uart_bready),
        .s2_arvalid(clint_arvalid), .s2_arready(clint_arready), .s2_araddr(clint_araddr), .s2_rvalid(clint_rvalid), .s2_rready(clint_rready), .s2_rdata(clint_rdata),
        .s2_awvalid(clint_awvalid), .s2_awready(clint_awready), .s2_awaddr(clint_awaddr), .s2_wvalid(clint_wvalid), .s2_wready(clint_wready), .s2_wdata(clint_wdata), .s2_wstrb(clint_wstrb), .s2_bvalid(clint_bvalid), .s2_bready(clint_bready)
    );

    axi_uart u_uart (
        .clk(clk), .rst(rst),
        .arvalid(uart_arvalid), .arready(uart_arready), .araddr(uart_araddr), .rvalid(uart_rvalid), .rready(uart_rready), .rdata(uart_rdata),
        .awvalid(uart_awvalid), .awready(uart_awready), .awaddr(uart_awaddr), .wvalid(uart_wvalid), .wready(uart_wready), .wdata(uart_wdata), .wstrb(uart_wstrb), .bvalid(uart_bvalid), .bready(uart_bready)
    );

    axi_clint u_clint (
        .clk(clk), .rst(rst),
        .arvalid(clint_arvalid), .arready(clint_arready), .araddr(clint_araddr), .rvalid(clint_rvalid), .rready(clint_rready), .rdata(clint_rdata),
        .awvalid(clint_awvalid), .awready(clint_awready), .awaddr(clint_awaddr), .wvalid(clint_wvalid), .wready(clint_wready), .wdata(clint_wdata), .wstrb(clint_wstrb), .bvalid(clint_bvalid), .bready(clint_bready)
    );

    reg sram_ar_busy; reg [3:0] sram_ar_delay; reg [31:0] sram_rdata_reg; reg sram_rvalid_reg;
    assign sram_arready = !sram_ar_busy && lfsr[1]; assign sram_rvalid  = sram_rvalid_reg; assign sram_rdata   = sram_rdata_reg;
    always @(posedge clk) begin
        if (rst) begin sram_ar_busy <= 0; sram_ar_delay <= 0; sram_rvalid_reg <= 0; end 
        else begin
            if (sram_arvalid && sram_arready) begin sram_ar_busy <= 1; sram_ar_delay <= lfsr[4:1]; end 
            else if (sram_ar_busy) begin
                if (sram_ar_delay == 0) begin sram_ar_busy <= 0; sram_rvalid_reg <= 1; sram_rdata_reg <= pmem_read(sram_araddr); end 
                else sram_ar_delay <= sram_ar_delay - 1;
            end else if (sram_rvalid && sram_rready) sram_rvalid_reg <= 0;
        end
    end

    reg sram_aw_busy, sram_w_busy; reg [31:0] pmem_waddr_reg, pmem_wdata_reg; reg [3:0] pmem_wstrb_reg; reg sram_bvalid_reg;
    assign sram_awready = !sram_aw_busy && lfsr[8]; assign sram_wready  = !sram_w_busy  && lfsr[9]; assign sram_bvalid  = sram_bvalid_reg;
    always @(posedge clk) begin
        if (rst) begin sram_aw_busy <= 0; sram_w_busy <= 0; sram_bvalid_reg <= 0; end 
        else begin
            if (sram_awvalid && sram_awready) begin sram_aw_busy <= 1; pmem_waddr_reg <= sram_awaddr; end
            if (sram_wvalid  && sram_wready)  begin sram_w_busy  <= 1; pmem_wdata_reg <= sram_wdata; pmem_wstrb_reg <= sram_wstrb; end
            if (sram_aw_busy && sram_w_busy && !sram_bvalid_reg) begin
                pmem_write(pmem_waddr_reg, pmem_wdata_reg, {4'b0, pmem_wstrb_reg}); sram_bvalid_reg <= 1;
            end else if (sram_bvalid && sram_bready) begin sram_aw_busy <= 0; sram_w_busy <= 0; sram_bvalid_reg <= 0; end
        end
    end

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
        else if (!stall) begin
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

    // =======================================================================
    // 【终极免检防线】计算是否需要跳过 DiffTest 并导出标志
    // =======================================================================
    // 任何不在 0x80~0x87 范围内的存取，都是 MMIO (支持 128MB)
    wire is_mmio = is_mem_inst && (mem_addr[31:27] != 5'b10000);
    // 任何时间或性能计数器的读取，也是不可比较的
    wire is_skip_csr = is_csr && (
        csr_addr == 12'hB00 || csr_addr == 12'hC00 || csr_addr == 12'hC01 || 
        csr_addr == 12'hB80 || csr_addr == 12'hC80 || csr_addr == 12'hC81 ||
        csr_addr == 12'hF11 || csr_addr == 12'hF12
    );
    
    // 生成一个与 commit 同步的免检标志
    reg skip_flag;
    always @(posedge clk) begin
        if (rst) skip_flag <= 1'b0;
        else skip_flag <= (!stall) && (is_mmio || is_skip_csr);
    end

    // 暴露给 C++ 调用
    export "DPI-C" function npc_check_skip;
    function int npc_check_skip; return skip_flag ? 32'd1 : 32'd0; endfunction
    // =======================================================================

    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg || is_csr);
    wire [31:0] rf_wdata = (is_csr) ? csr_rdata_internal : (op_jal || op_jalr) ? snpc : (op_load) ? ext_mem_rdata : alu_result; 

    regfile u_regfile (.clk(clk), .rst(rst), .wen(rf_wen && !stall), .waddr(rd_idx), .wdata(rf_wdata), .raddr1(rs1_idx), .raddr2(rs2_idx), .rdata1(rs1_data), .rdata2(rs2_data), .a0_val(a0_val));

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

// 仲裁器
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

// 交叉开关 (支持 128MB SRAM)
module axi_xbar_1to3(
    input wire clk, input wire rst,
    input  wire m_arvalid, output wire m_arready, input  wire [31:0] m_araddr, output wire m_rvalid,  input  wire m_rready,  output wire [31:0] m_rdata,
    input  wire m_awvalid, output wire m_awready, input  wire [31:0] m_awaddr, input  wire m_wvalid,  output wire m_wready,  input  wire [31:0] m_wdata, input wire [3:0] m_wstrb, output wire m_bvalid,  input  wire m_bready,
    output wire s0_arvalid, input wire s0_arready, output wire [31:0] s0_araddr, input wire s0_rvalid, output wire s0_rready, input wire [31:0] s0_rdata,
    output wire s0_awvalid, input wire s0_awready, output wire [31:0] s0_awaddr, output wire s0_wvalid, input wire s0_wready, output wire [31:0] s0_wdata, output wire [3:0] s0_wstrb, input wire s0_bvalid, output wire s0_bready,
    output wire s1_arvalid, input wire s1_arready, output wire [31:0] s1_araddr, input wire s1_rvalid, output wire s1_rready, input wire [31:0] s1_rdata,
    output wire s1_awvalid, input wire s1_awready, output wire [31:0] s1_awaddr, output wire s1_wvalid, input wire s1_wready, output wire [31:0] s1_wdata, output wire [3:0] s1_wstrb, input wire s1_bvalid, output wire s1_bready,
    output wire s2_arvalid, input wire s2_arready, output wire [31:0] s2_araddr, input wire s2_rvalid, output wire s2_rready, input wire [31:0] s2_rdata,
    output wire s2_awvalid, input wire s2_awready, output wire [31:0] s2_awaddr, output wire s2_wvalid, input wire s2_wready, output wire [31:0] s2_wdata, output wire [3:0] s2_wstrb, input wire s2_bvalid, output wire s2_bready
);
    wire sel_uart = (m_araddr[31:12] == 20'h10000);
    wire sel_clint = (m_araddr[31:24] == 8'ha0) || (m_araddr[31:24] == 8'h02); 
    
    // 【核心修复】：放宽 SRAM 读通道地址译码，支持 0x80000000 ~ 0x87FFFFFF (128MB)
    wire sel_sram = (m_araddr[31:27] == 5'b10000);
    
    wire sel_none = !(sel_uart || sel_clint || sel_sram); 
    
    assign s1_arvalid = m_arvalid && sel_uart; assign s0_arvalid = m_arvalid && sel_sram; assign s2_arvalid = m_arvalid && sel_clint;
    assign s1_araddr = m_araddr; assign s0_araddr = m_araddr; assign s2_araddr = m_araddr;
    assign m_arready = sel_uart ? s1_arready : sel_sram ? s0_arready : sel_clint ? s2_arready : sel_none ? 1'b1 : 1'b0;

    reg fake_rvalid;
    always @(posedge clk) begin
        if (rst) fake_rvalid <= 0; else if (m_arvalid && m_arready && sel_none) fake_rvalid <= 1; else if (m_rvalid && m_rready) fake_rvalid <= 0;
    end
    assign m_rvalid = fake_rvalid | s1_rvalid | s0_rvalid | s2_rvalid;
    assign m_rdata  = fake_rvalid ? 32'h0 : (s1_rvalid ? s1_rdata : (s2_rvalid ? s2_rdata : s0_rdata));
    assign s1_rready = m_rready && s1_rvalid; assign s0_rready = m_rready && s0_rvalid; assign s2_rready = m_rready && s2_rvalid;

    wire sel_uart_w = (m_awaddr[31:12] == 20'h10000);
    wire sel_clint_w = (m_awaddr[31:24] == 8'ha0) || (m_awaddr[31:24] == 8'h02);
    
    // 【核心修复】：放宽 SRAM 写通道地址译码，支持 0x80000000 ~ 0x87FFFFFF (128MB)
    wire sel_sram_w = (m_awaddr[31:27] == 5'b10000);
    
    wire sel_none_w = !(sel_uart_w || sel_clint_w || sel_sram_w);

    assign s1_awvalid = m_awvalid && sel_uart_w; assign s0_awvalid = m_awvalid && sel_sram_w; assign s2_awvalid = m_awvalid && sel_clint_w;
    assign s1_awaddr = m_awaddr; assign s0_awaddr = m_awaddr; assign s2_awaddr = m_awaddr;
    assign m_awready = sel_uart_w ? s1_awready : sel_sram_w ? s0_awready : sel_clint_w ? s2_awready : sel_none_w ? 1'b1 : 1'b0;

    assign s1_wvalid = m_wvalid && sel_uart_w; assign s0_wvalid = m_wvalid && sel_sram_w; assign s2_wvalid = m_wvalid && sel_clint_w;
    assign s1_wdata = m_wdata; assign s0_wdata = m_wdata; assign s2_wdata = m_wdata;
    assign s1_wstrb = m_wstrb; assign s0_wstrb = m_wstrb; assign s2_wstrb = m_wstrb;
    assign m_wready = sel_uart_w ? s1_wready : sel_sram_w ? s0_wready : sel_clint_w ? s2_wready : sel_none_w ? 1'b1 : 1'b0;

    reg fake_bvalid;
    always @(posedge clk) begin
        if (rst) fake_bvalid <= 0; else if (m_awvalid && m_awready && sel_none_w) fake_bvalid <= 1; else if (m_bvalid && m_bready) fake_bvalid <= 0;
    end
    assign m_bvalid = fake_bvalid | s1_bvalid | s0_bvalid | s2_bvalid;
    assign s1_bready = m_bready && s1_bvalid; assign s0_bready = m_bready && s0_bvalid; assign s2_bready = m_bready && s2_bvalid;
endmodule

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

module axi_uart(
    input clk, input rst,
    input  wire arvalid, output wire arready, input wire [31:0] araddr, output wire rvalid, input wire rready, output wire [31:0] rdata,
    input  wire awvalid, output wire awready, input wire [31:0] awaddr, input wire wvalid, output wire wready, input wire [31:0] wdata, input wire [3:0] wstrb, output wire bvalid, input wire bready
);
    reg bvalid_reg;
    always @(posedge clk) begin
         if (rst) bvalid_reg <= 0;
         else if (awvalid && wvalid && !bvalid_reg) begin
             $write("%c", wdata[7:0]); bvalid_reg <= 1;
         end else if (bvalid_reg && bready) bvalid_reg <= 0;
    end
    assign awready = !bvalid_reg; assign wready = !bvalid_reg; assign bvalid = bvalid_reg;

    reg rvalid_reg;
    always @(posedge clk) begin
         if (rst) rvalid_reg <= 0;
         else if (arvalid && !rvalid_reg) begin rvalid_reg <= 1; end
         else if (rvalid_reg && rready) rvalid_reg <= 0;
    end
    assign arready = !rvalid_reg; assign rvalid = rvalid_reg; assign rdata = 32'h00000020; 
endmodule