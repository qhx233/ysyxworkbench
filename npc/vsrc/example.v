/*module example(
    input wire       clk,
    input wire       rst,
    output reg [31:0] pc
);
    wire [31:0] rs1_data;
    wire [31:0] rs2_data;
    wire [31:0] alu_result;
    wire [31:0] a0_val; // 从寄存器文件中监视 a0 的值

//===========================================================================
// 4.DPI-C
//===========================================================================
import "DPI-C" function void npc_trap(input int a0_val);
import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);
import "DPI-C" function int  pmem_read(input int raddr);
import "DPI-C" function void npc_itrace_commit(input int pc, input int inst, input int dnpc);

//===========================================================================
// 1. IDU
//===========================================================================
    reg [31:0] inst;
    wire [4:0] rs1_idx = inst[19:15];
    wire [4:0] rs2_idx = inst[24:20];
    wire [4:0] rd_idx  = inst[11:7];
    wire [31:0] imm_I = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_S = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_U = {inst[31:12], 12'b0};

    // 识别具体指令
    wire is_add    = (inst[6:0] == 7'b0110011) && (inst[14:12] == 3'b000) && (inst[31:25] == 7'b0000000);
    wire is_addi   = (inst[6:0] == 7'b0010011) && (inst[14:12] == 3'b000);
    wire is_lui    = (inst[6:0] == 7'b0110111);
    wire is_lw     = (inst[6:0] == 7'b0000011) && (inst[14:12] == 3'b010);
    wire is_lbu    = (inst[6:0] == 7'b0000011) && (inst[14:12] == 3'b100);
    wire is_sw     = (inst[6:0] == 7'b0100011) && (inst[14:12] == 3'b010);
    wire is_sb     = (inst[6:0] == 7'b0100011) && (inst[14:12] == 3'b000);
    wire is_jalr   = (inst[6:0] == 7'b1100111) && (inst[14:12] == 3'b000);
    wire is_ebreak = (inst == 32'h00100073);

//===========================================================================
// 2. IFU
//===========================================================================

    always @(*) begin
        if (rst) begin
            inst = 32'h0;
        end else begin
            inst = pmem_read(pc); // DPI-C 函数必须在 always 块中调用
        end
    end
wire [31:0] snpc = pc + 32'h4; // Sequential Next PC (顺序下一条的PC)
    
    // Dynamic Next PC (动态下一条的PC)
    // 如果是 jalr，目标地址是 (rs1 + imm) 且最低位清零；否则就是 snpc
    wire [31:0] dnpc = is_jalr ? ((rs1_data + imm_I) & ~32'h1) : snpc; 

    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'h80000000;
        end else begin
            pc <= dnpc; // 使用动态 PC，允许指令打断顺序执行
        end
    end

wire rf_wen = is_addi | is_add | is_lui | is_lw | is_lbu | is_jalr;

wire [3:0] alu_op = is_addi | is_jalr ? 4'b0000 : 4'b0000; 
wire [31:0] alu_src1 = is_lui ? 32'h0 : rs1_data; // lui 的 src1 强制为 0
wire [31:0] alu_src2 = (is_addi | is_lw | is_lbu | is_jalr) ? imm_I:
                           (is_sw | is_sb) ? imm_S :
                           is_lui ? imm_U :
                           rs2_data;


wire [31:0] mem_addr = alu_result & ~32'h3; // load/store 的地址由 ALU 计算得到
wire [1:0] mem_offset = alu_result[1:0]; // load/store 的地址偏移量
wire mem_ren = is_lw | is_lbu; // 读内存的信号
reg [31:0] raw_rdata;
always @(*) begin
        if (mem_ren && !rst) begin
            raw_rdata = pmem_read(mem_addr);
        end else begin
            raw_rdata = 32'h0;
        end
    end
wire [7:0] byte_data = (mem_offset == 2'b00) ? raw_rdata[7:0]  :
                           (mem_offset == 2'b01) ? raw_rdata[15:8] :
                           (mem_offset == 2'b10) ? raw_rdata[23:16] :
                                                   raw_rdata[31:24];
wire [31:0] lbu_data = {24'h0, byte_data};
wire [31:0] mem_rdata = is_lw ? raw_rdata : lbu_data;
wire [31:0] rf_wdata = is_jalr ? snpc :
                           (is_lw | is_lbu) ? mem_rdata : 
                           alu_result;

wire mem_wen = is_sw | is_sb; // 写内存的信号

    
wire [7:0] wmask = is_sw ? 8'b0000_1111 : 
                       is_sb ? (8'b0000_0001 << mem_offset) : 8'h00;
wire [31:0] wdata = is_sw ? rs2_data : 
                        is_sb ? {4{rs2_data[7:0]}} : 32'h0;
always @(posedge clk) begin
        if (mem_wen && !rst) begin
            pmem_write(mem_addr, wdata, wmask);
        end
    end

//===========================================================================
// 3.实例化
//===========================================================================


    regfile u_regfile (
        .clk(clk),
        .rst(rst),
        .wen(rf_wen),
        .waddr(rd_idx),
        .wdata(rf_wdata),
        .raddr1(rs1_idx),
        .raddr2(rs2_idx),
        .rdata1(rs1_data),
        .rdata2(rs2_data),
        .a0_val(a0_val) // 监视 a0 寄存器的值
    );

export "DPI-C" function npc_read_gpr;
function int npc_read_gpr(input int idx);
        return u_regfile.rf[idx];
endfunction

    alu u_alu (
        .src1(alu_src1),
        .src2(alu_src2),
        .alu_op(alu_op),
        .result(alu_result)
    ); 


    always @(posedge clk) begin
        if (is_ebreak) begin
            // 遇到 ebreak 时，不再使用 $finish，而是直接调用 C++ 函数
            npc_trap(a0_val); 
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            npc_itrace_commit(pc, inst,dnpc);
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
    // IFU (Instruction Fetch Unit)
    //===========================================================================
    reg [31:0] inst;
    always @(*) begin
        if (rst) inst = 32'h0;
        else     inst = pmem_read(pc);
    end

    //===========================================================================
    // IDU (Instruction Decode Unit)
    //===========================================================================
    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    wire [4:0] rs1_idx = inst[19:15];
    wire [4:0] rs2_idx = inst[24:20];
    wire [4:0] rd_idx  = inst[11:7];

    // 立即数提取 (RV32 所有的立即数格式)
    wire [31:0] imm_I = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_S = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_B = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_U = {inst[31:12], 12'b0};
    wire [31:0] imm_J = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};

    // 指令类型解码
    wire op_lui    = (opcode == 7'b0110111);
    wire op_auipc  = (opcode == 7'b0010111);
    wire op_jal    = (opcode == 7'b1101111);
    wire op_jalr   = (opcode == 7'b1100111);
    wire op_branch = (opcode == 7'b1100011);
    wire op_load   = (opcode == 7'b0000011);
    wire op_store  = (opcode == 7'b0100011);
    wire op_imm    = (opcode == 7'b0010011);
    wire op_reg    = (opcode == 7'b0110011);
    wire is_ebreak = (inst == 32'h00100073);

    //===========================================================================
    // EXU (Execution Unit - Branch & ALU)
    //===========================================================================
    // --- 1. 分支判断逻辑 (Branch Unit) ---
    wire alu_eq  = (rs1_data == rs2_data);
    wire alu_lt  = ($signed(rs1_data) < $signed(rs2_data));
    wire alu_ltu = (rs1_data < rs2_data);

    wire branch_taken = op_branch && (
        (funct3 == 3'b000 &&  alu_eq) || // BEQ
        (funct3 == 3'b001 && !alu_eq) || // BNE
        (funct3 == 3'b100 &&  alu_lt) || // BLT
        (funct3 == 3'b101 && !alu_lt) || // BGE
        (funct3 == 3'b110 &&  alu_ltu)|| // BLTU
        (funct3 == 3'b111 && !alu_ltu)   // BGEU
    );

    // --- 2. PC 更新逻辑 ---
    wire [31:0] snpc = pc + 32'h4;
    wire [31:0] dnpc = (op_jal)       ? (pc + imm_J) :
                       (op_jalr)      ? ((rs1_data + imm_I) & ~32'h1) :
                       (branch_taken) ? (pc + imm_B) : 
                       snpc;

    always @(posedge clk) begin
        if (rst) pc <= 32'h80000000;
        else     pc <= dnpc;
    end

    // --- 3. ALU 控制逻辑 ---
    // ALU 操作码设计：[3] 区分加/减或右移的逻辑/算数, [2:0] 完美对应 funct3
    wire is_sub = (op_reg && funct7[5]) || op_branch; 
    wire is_sra = (funct7[5] && (op_reg || op_imm) && funct3 == 3'b101);
    wire [3:0] alu_op = (op_lui || op_auipc || op_jal || op_load || op_store) ? 4'b0000 : 
                        { (is_sub || is_sra), funct3 };

    // --- 4. ALU 输入多路选择器 ---
    wire [31:0] alu_src1 = (op_auipc) ? pc :
                           (op_lui)   ? 32'b0 : 
                           rs1_data;

    wire [31:0] alu_src2 = (op_imm || op_load || op_jalr) ? imm_I :
                           (op_store)                     ? imm_S :
                           (op_lui || op_auipc)           ? imm_U :
                           rs2_data;

    //===========================================================================
    // LSU (Load/Store Unit)
    //===========================================================================
    wire [31:0] mem_addr   = alu_result & ~32'h3; 
    wire [1:0]  mem_offset = alu_result[1:0];
    
    wire mem_ren = op_load;
    wire mem_wen = op_store;

    reg [31:0] raw_rdata;
    always @(*) begin
        if (mem_ren && !rst) raw_rdata = pmem_read(mem_addr);
        else                 raw_rdata = 32'h0;
    end

    // 读取对齐处理 (LB, LH, LW, LBU, LHU)
    wire [7:0] byte_data = (mem_offset == 2'b00) ? raw_rdata[7:0]   :
                           (mem_offset == 2'b01) ? raw_rdata[15:8]  :
                           (mem_offset == 2'b10) ? raw_rdata[23:16] : raw_rdata[31:24];

    wire [15:0] half_data = (mem_offset[1] == 1'b0) ? raw_rdata[15:0] : raw_rdata[31:16];

    wire [31:0] mem_rdata = 
        (funct3 == 3'b000) ? {{24{byte_data[7]}}, byte_data}   : // LB
        (funct3 == 3'b001) ? {{16{half_data[15]}}, half_data}  : // LH
        (funct3 == 3'b010) ? raw_rdata                         : // LW
        (funct3 == 3'b100) ? {24'b0, byte_data}                : // LBU
        (funct3 == 3'b101) ? {16'b0, half_data}                : // LHU
        32'b0;

    // 写入对齐与掩码处理 (SB, SH, SW)
    wire [7:0] wmask = 
        (funct3 == 3'b000) ? (8'b0000_0001 << mem_offset) : // SB
        (funct3 == 3'b001) ? (8'b0000_0011 << mem_offset) : // SH
        (funct3 == 3'b010) ? 8'b0000_1111                 : // SW
        8'b0;

    wire [31:0] wdata = 
        (funct3 == 3'b000) ? {4{rs2_data[7:0]}}  : // SB
        (funct3 == 3'b001) ? {2{rs2_data[15:0]}} : // SH
        rs2_data;                                  // SW

    always @(posedge clk) begin
        if (mem_wen && !rst) pmem_write(mem_addr, wdata, wmask);
    end

    //===========================================================================
    // WBU (Write Back Unit)
    //===========================================================================
    wire rf_wen = (op_lui || op_auipc || op_jal || op_jalr || op_load || op_imm || op_reg);
    wire [31:0] rf_wdata = (op_jal || op_jalr) ? snpc :
                           (op_load)           ? mem_rdata : 
                           alu_result; // LUI, AUIPC, OP-IMM, OP 都在 ALU 里算好了

    //===========================================================================
    // 实例化与追踪
    //===========================================================================
    regfile u_regfile (
        .clk(clk),
        .rst(rst),
        .wen(rf_wen),
        .waddr(rd_idx),
        .wdata(rf_wdata),
        .raddr1(rs1_idx),
        .raddr2(rs2_idx),
        .rdata1(rs1_data),
        .rdata2(rs2_data),
        .a0_val(a0_val) 
    );

    export "DPI-C" function npc_read_gpr;
    function int npc_read_gpr(input int idx);
        return u_regfile.rf[idx];
    endfunction

    alu u_alu (
        .src1(alu_src1),
        .src2(alu_src2),
        .alu_op(alu_op),
        .result(alu_result)
    ); 

    always @(posedge clk) begin
        if (is_ebreak) npc_trap(a0_val); 
        if (!rst)      npc_itrace_commit(pc, inst, dnpc);
    end

endmodule