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
    // 2. 取指阶段 (IFU) 声明与内存模拟
    //===========================================================================
    wire ifu_reqValid  = (state == ST_IF_REQ);
    wire ifu_respReady = (state == ST_IF_RSP);

    reg ifu_busy;
    reg [3:0] ifu_delay;
    reg [31:0] ifu_rdata_reg;
    reg ifu_respValid_reg;
    
    wire ifu_reqReady  = !ifu_busy && lfsr[1]; // 随机 Ready
    wire ifu_respValid = ifu_respValid_reg;
    wire [31:0] ifu_rdata = ifu_rdata_reg;

    always @(posedge clk) begin
        if (rst) begin
            ifu_busy <= 1'b0; ifu_delay <= 4'b0; ifu_respValid_reg <= 1'b0;
        end else begin
            ifu_respValid_reg <= 1'b0;
            if (ifu_reqValid && ifu_reqReady) begin
                ifu_busy  <= 1'b1;
                ifu_delay <= lfsr[5:2]; 
            end else if (ifu_busy) begin
                if (ifu_delay == 4'b0) begin
                    ifu_busy <= 1'b0; ifu_respValid_reg <= 1'b1;
                    ifu_rdata_reg <= pmem_read(pc);
                end else if (lfsr[6]) begin 
                    ifu_delay <= ifu_delay - 1'b1;
                end
            end
        end
    end

    wire ifu_hsk_req = ifu_reqValid && ifu_reqReady;
    wire ifu_hsk_rsp = ifu_respValid && ifu_respReady;

    reg [31:0] inst_reg;
    always @(posedge clk) begin
        if (rst)              inst_reg <= 32'h00000013;
        else if (ifu_hsk_rsp) inst_reg <= ifu_rdata;
    end
    wire [31:0] inst = (ifu_hsk_rsp) ? ifu_rdata : inst_reg;

    //===========================================================================
    // 3. 译码前置 (Decode)
    //===========================================================================
    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    wire op_load  = (opcode == 7'b0000011);
    wire op_store = (opcode == 7'b0100011);
    wire is_mem_inst = op_load || op_store;

    wire lsu_ren = op_load;
    wire lsu_wen = op_store;

    //===========================================================================
    // 4. 访存阶段 (LSU) 声明与内存模拟
    //===========================================================================
    wire lsu_reqValid  = (state == ST_MEM_REQ);
    wire lsu_respReady = (state == ST_MEM_RSP);

    reg lsu_busy;
    reg [3:0] lsu_delay;
    reg [31:0] lsu_rdata_reg;
    reg lsu_respValid_reg;

    wire lsu_reqReady  = !lsu_busy && lfsr[7];
    wire lsu_respValid = lsu_respValid_reg;
    wire [31:0] lsu_rdata = lsu_rdata_reg;

    wire lsu_hsk_req = lsu_reqValid && lsu_reqReady;
    wire lsu_hsk_rsp = lsu_respValid && lsu_respReady;

    //===========================================================================
    // 5. 状态机跳转与流水线 Stall
    //===========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IF_REQ;
        end else begin
            case (state)
                ST_IF_REQ:  if (ifu_hsk_req) state <= ST_IF_RSP;
                ST_IF_RSP:  if (ifu_hsk_rsp) state <= is_mem_inst ? ST_MEM_REQ : ST_IF_REQ;
                ST_MEM_REQ: if (lsu_hsk_req) state <= ST_MEM_RSP;
                ST_MEM_RSP: if (lsu_hsk_rsp) state <= ST_IF_REQ;
                default:    state <= ST_IF_REQ;
            endcase
        end
    end

    wire commit_non_mem = (state == ST_IF_RSP)  && ifu_hsk_rsp && !is_mem_inst;
    wire commit_mem     = (state == ST_MEM_RSP) && lsu_hsk_rsp;
    wire stall = !(commit_non_mem || commit_mem);

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
    // 7. LSU 地址与数据逻辑提取
    //===========================================================================
    wire [31:0] lsu_addr   = alu_result & ~32'h3; 
    wire [1:0]  mem_offset = alu_result[1:0];

    wire [7:0] wmask = (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : 
                       (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : 
                       (funct3 == 3'b010) ? 8'b0000_1111 : 8'b0;
    wire [31:0] wdata = (funct3 == 3'b000) ? {4{rs2_data[7:0]}}  : 
                        (funct3 == 3'b001) ? {2{rs2_data[15:0]}} : rs2_data; 

    // LSU 响应内存的具体动作
    always @(posedge clk) begin
        if (rst) begin
            lsu_busy <= 1'b0; lsu_delay <= 4'b0; lsu_respValid_reg <= 1'b0;
        end else begin
            lsu_respValid_reg <= 1'b0;
            if (lsu_reqValid && lsu_reqReady) begin
                lsu_busy  <= 1'b1;
                lsu_delay <= lfsr[11:8]; 
            end else if (lsu_busy) begin
                if (lsu_delay == 4'b0) begin
                    lsu_busy <= 1'b0; lsu_respValid_reg <= 1'b1;
                    if (lsu_ren) lsu_rdata_reg <= pmem_read(lsu_addr);
                    if (lsu_wen) pmem_write(lsu_addr, wdata, wmask);
                end else if (lfsr[12]) begin
                    lsu_delay <= lsu_delay - 1'b1;
                end
            end
        end
    end

    wire [7:0] byte_data = (mem_offset == 2'b00) ? lsu_rdata[7:0]   :
                           (mem_offset == 2'b01) ? lsu_rdata[15:8]  :
                           (mem_offset == 2'b10) ? lsu_rdata[23:16] : lsu_rdata[31:24];
    wire [15:0] half_data = (mem_offset[1] == 1'b0) ? lsu_rdata[15:0] : lsu_rdata[31:16];

    wire [31:0] mem_rdata = 
        (funct3 == 3'b000) ? {{24{byte_data[7]}}, byte_data}   : 
        (funct3 == 3'b001) ? {{16{half_data[15]}}, half_data}  : 
        (funct3 == 3'b010) ? lsu_rdata                         : 
        (funct3 == 3'b100) ? {24'b0, byte_data}                : 
        (funct3 == 3'b101) ? {16'b0, half_data}                : 
        32'b0;

    //===========================================================================
    // 8. CSR / 控制与状态寄存器
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

    //===========================================================================
    // 9. 写回逻辑 (WBU)
    //===========================================================================
    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg || is_csr);
    wire [31:0] rf_wdata = (is_csr)            ? csr_rdata_internal :
                           (op_jal || op_jalr) ? snpc               :
                           (op_load)           ? mem_rdata          : alu_result; 

    //===========================================================================
    // 10. 寄存器堆实例化
    //===========================================================================
    regfile u_regfile (
        .clk(clk), .rst(rst), 
        .wen(rf_wen && !stall), 
        .waddr(rd_idx), .wdata(rf_wdata),
        .raddr1(rs1_idx), .raddr2(rs2_idx), .rdata1(rs1_data), .rdata2(rs2_data), 
        .a0_val(a0_val) 
    );

    //===========================================================================
    // 11. DPI-C 输出跟踪
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
endmodule