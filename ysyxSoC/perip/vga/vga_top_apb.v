module vga_top_apb(
  input         clock,
  input         reset,
  input  [31:0] in_paddr,
  input         in_psel,
  input         in_penable,
  input  [2:0]  in_pprot,
  input         in_pwrite,
  input  [31:0] in_pwdata,
  input  [3:0]  in_pstrb,
  output        in_pready,
  output [31:0] in_prdata,
  output        in_pslverr,

  output [7:0]  vga_r,
  output [7:0]  vga_g,
  output [7:0]  vga_b,
  output        vga_hsync,
  output        vga_vsync,
  output        vga_valid
);

  localparam H_VISIBLE = 10'd640;
  localparam H_FRONT   = 10'd16;
  localparam H_SYNC    = 10'd96;
  localparam H_BACK    = 10'd48;
  localparam H_TOTAL   = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;

  localparam V_VISIBLE = 10'd480;
  localparam V_FRONT   = 10'd10;
  localparam V_SYNC    = 10'd2;
  localparam V_BACK    = 10'd33;
  localparam V_TOTAL   = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

  localparam FB_WIDTH  = 640;
  localparam FB_HEIGHT = 480;
  localparam FB_SIZE   = FB_WIDTH * FB_HEIGHT;

  reg [31:0] fb [0:FB_SIZE-1];

  wire        apb_access = in_psel & in_penable;
  wire        apb_write  = apb_access & in_pwrite;
  wire [18:0] fb_waddr   = in_paddr[20:2];
  wire        fb_wen     = apb_write & (fb_waddr < FB_SIZE);

  reg [31:0] rdata;
  assign in_pready  = 1'b1;
  assign in_prdata  = rdata;
  assign in_pslverr = 1'b0;

  always @(posedge clock) begin
    if (fb_wen) begin
      if (in_pstrb[0]) fb[fb_waddr][7:0]   <= in_pwdata[7:0];
      if (in_pstrb[1]) fb[fb_waddr][15:8]  <= in_pwdata[15:8];
      if (in_pstrb[2]) fb[fb_waddr][23:16] <= in_pwdata[23:16];
      if (in_pstrb[3]) fb[fb_waddr][31:24] <= in_pwdata[31:24];
`ifdef VGA_DEBUG
      if (debug_write_count < 32) begin
        $display("[VGA] write addr=0x%08x fb[%0d] data=0x%08x strb=0x%x",
                 in_paddr, fb_waddr, in_pwdata, in_pstrb);
        debug_write_count <= debug_write_count + 1;
      end
`endif
    end

    if (apb_access & !in_pwrite) begin
      rdata <= (fb_waddr < FB_SIZE) ? fb[fb_waddr] : 32'h0;
    end
  end

  reg [9:0] h_cnt;
  reg [9:0] v_cnt;

  always @(posedge clock) begin
    if (reset) begin
      h_cnt <= 10'd0;
      v_cnt <= 10'd0;
    end else if (h_cnt == H_TOTAL - 1'b1) begin
      h_cnt <= 10'd0;
      if (v_cnt == V_TOTAL - 1'b1) begin
        v_cnt <= 10'd0;
      end else begin
        v_cnt <= v_cnt + 1'b1;
      end
    end else begin
      h_cnt <= h_cnt + 1'b1;
    end
  end

  wire visible = (h_cnt < H_VISIBLE) & (v_cnt < V_VISIBLE);
  wire [18:0] scan_line_base = {9'b0, v_cnt} * 19'd640;
  wire [18:0] scan_addr = scan_line_base + {9'b0, h_cnt};
  wire [31:0] scan_pixel = visible ? fb[scan_addr] : 32'h0;

  assign vga_valid = visible;
  assign vga_hsync = ~((h_cnt >= H_VISIBLE + H_FRONT) &
                       (h_cnt <  H_VISIBLE + H_FRONT + H_SYNC));
  assign vga_vsync = ~((v_cnt >= V_VISIBLE + V_FRONT) &
                       (v_cnt <  V_VISIBLE + V_FRONT + V_SYNC));
  assign vga_r = visible ? scan_pixel[23:16] : 8'h00;
  assign vga_g = visible ? scan_pixel[15:8]  : 8'h00;
  assign vga_b = visible ? scan_pixel[7:0]   : 8'h00;

`ifdef VGA_DEBUG
  reg [5:0] debug_write_count;
  initial begin
    debug_write_count = 6'd0;
  end
`endif

endmodule
