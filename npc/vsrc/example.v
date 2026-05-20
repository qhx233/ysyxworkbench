module example(
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
endmodule