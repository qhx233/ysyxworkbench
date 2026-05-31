/*module axi_arbiter(
    input wire clk,
    input wire rst,

    // -----------------------------------------
    // Master 0: IFU (只读)
    // -----------------------------------------
    input  wire        ifu_arvalid,
    output wire        ifu_arready,
    input  wire [31:0] ifu_araddr,
    output wire        ifu_rvalid,
    input  wire        ifu_rready,
    output wire [31:0] ifu_rdata,

    // -----------------------------------------
    // Master 1: LSU (读写)
    // -----------------------------------------
    input  wire        lsu_arvalid,
    output wire        lsu_arready,
    input  wire [31:0] lsu_araddr,
    output wire        lsu_rvalid,
    input  wire        lsu_rready,
    output wire [31:0] lsu_rdata,

    input  wire        lsu_awvalid,
    output wire        lsu_awready,
    input  wire [31:0] lsu_awaddr,
    input  wire        lsu_wvalid,
    output wire        lsu_wready,
    input  wire [31:0] lsu_wdata,
    input  wire [3:0]  lsu_wstrb,
    output wire        lsu_bvalid,
    input  wire        lsu_bready,

    // -----------------------------------------
    // Slave: 物理内存
    // -----------------------------------------
    output wire        mem_arvalid,
    input  wire        mem_arready,
    output wire [31:0] mem_araddr,
    input  wire        mem_rvalid,
    output wire        mem_rready,
    input  wire [31:0] mem_rdata,

    output wire        mem_awvalid,
    input  wire        mem_awready,
    output wire [31:0] mem_awaddr,
    output wire        mem_wvalid,
    input  wire        mem_wready,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_bvalid,
    output wire        mem_bready
);

    //===========================================================================
    // 1. 写通道 (AW, W, B) 旁路直通 (Bypass)
    // 因为 IFU 不写内存，LSU 独占写通道，直接硬连线！
    //===========================================================================
    assign mem_awvalid = lsu_awvalid;
    assign lsu_awready = mem_awready;
    assign mem_awaddr  = lsu_awaddr;

    assign mem_wvalid  = lsu_wvalid;
    assign lsu_wready  = mem_wready;
    assign mem_wdata   = lsu_wdata;
    assign mem_wstrb   = lsu_wstrb;

    assign lsu_bvalid  = mem_bvalid;
    assign mem_bready  = lsu_bready;

    //===========================================================================
    // 2. 读通道 (AR, R) 仲裁状态机
    //===========================================================================
    localparam IDLE      = 2'b00;
    localparam GRANT_LSU = 2'b01;
    localparam GRANT_IFU = 2'b10;
    
    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    // 优先级调度：如果 LSU 和 IFU 同时请求，LSU 优先
                    if (lsu_arvalid)      state <= GRANT_LSU;
                    else if (ifu_arvalid) state <= GRANT_IFU;
                end
                GRANT_LSU: begin
                    // 只有当 R 通道的数据成功返回并被接收 (握手完成)，才释放总线
                    if (mem_rvalid && mem_rready) state <= IDLE;
                end
                GRANT_IFU: begin
                    // 同理，等待 IFU 成功拿到数据
                    if (mem_rvalid && mem_rready) state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    //===========================================================================
    // 3. 读通道信号路由 (MUX)
    // 根据状态机决定将谁的请求连到内存，以及将内存的数据回传给谁
    //===========================================================================
    // AR 通道 (请求路由到内存)
    assign mem_arvalid = (state == GRANT_LSU) ? lsu_arvalid :
                         (state == GRANT_IFU) ? ifu_arvalid : 1'b0;
    assign mem_araddr  = (state == GRANT_LSU) ? lsu_araddr  :
                         (state == GRANT_IFU) ? ifu_araddr  : 32'b0;
                         
    // AR 响应 (内存路由回 Master)
    assign lsu_arready = (state == GRANT_LSU) ? mem_arready : 1'b0;
    assign ifu_arready = (state == GRANT_IFU) ? mem_arready : 1'b0;

    // R 响应准备 (路由到内存)
    assign mem_rready  = (state == GRANT_LSU) ? lsu_rready :
                         (state == GRANT_IFU) ? ifu_rready : 1'b0;

    // R 通道数据与有效信号 (路由回 Master)
    assign lsu_rvalid  = (state == GRANT_LSU) ? mem_rvalid : 1'b0;
    assign ifu_rvalid  = (state == GRANT_IFU) ? mem_rvalid : 1'b0;
    
    // 数据线可以直接广播给所有人，只要 valid 信号不给，他们就不会误收
    assign lsu_rdata   = mem_rdata;
    assign ifu_rdata   = mem_rdata;

endmodule*/