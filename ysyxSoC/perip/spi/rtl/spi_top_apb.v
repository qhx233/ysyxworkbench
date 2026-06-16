// APB wrapper for the OpenCores SPI master.
// The XIP flash window drives the SPI master with an internal FSM.

`include "spi_defines.v"

module spi_top_apb #(
  parameter flash_addr_start = 32'h30000000,
  parameter flash_addr_end   = 32'h3fffffff,
  parameter spi_ss_num       = 8
) (
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

  output                  spi_sck,
  output [spi_ss_num-1:0] spi_ss,
  output                  spi_mosi,
  input                   spi_miso,
  output                  spi_irq_out
);

  localparam [4:0] WB_TX0  = (`SPI_TX_0   << 2);
  localparam [4:0] WB_TX1  = (`SPI_TX_1   << 2);
  localparam [4:0] WB_RX0  = (`SPI_RX_0   << 2);
  localparam [4:0] WB_CTRL = (`SPI_CTRL   << 2);
  localparam [4:0] WB_DIV  = (`SPI_DEVIDE << 2);
  localparam [4:0] WB_SS   = (`SPI_SS     << 2);

  localparam [31:0] CTRL_XIP = (32'h1 << `SPI_CTRL_ASS) |
                               (32'h1 << `SPI_CTRL_IE)  |
                               (32'h1 << `SPI_CTRL_TX_NEGEDGE) |
                               (32'h1 << `SPI_CTRL_GO)  |
                               32'd64;

  localparam [3:0] X_IDLE      = 4'd0;
  localparam [3:0] X_W_TX0     = 4'd1;
  localparam [3:0] X_W_TX1     = 4'd2;
  localparam [3:0] X_W_DIV     = 4'd3;
  localparam [3:0] X_W_SS      = 4'd4;
  localparam [3:0] X_W_CTRL    = 4'd5;
  localparam [3:0] X_WAIT_IRQ  = 4'd6;
  localparam [3:0] X_R_RX0     = 4'd7;
  localparam [3:0] X_RESP      = 4'd8;

  wire unused_pprot = |in_pprot;
  wire in_flash = (in_paddr >= flash_addr_start) && (in_paddr < flash_addr_end);
  wire xip_active = (xip_state != X_IDLE);
  wire xip_start = in_psel && !in_penable && in_flash && !xip_active;
  wire normal_access = in_psel && !in_flash && !xip_active;

  reg [3:0] xip_state;
  reg [31:0] xip_addr;
  reg [31:0] xip_rdata;
  reg xip_error;

  reg        xip_wb_cyc;
  reg        xip_wb_stb;
  reg        xip_wb_we;
  reg [4:0]  xip_wb_adr;
  reg [31:0] xip_wb_dat;
  reg [3:0]  xip_wb_sel;

  wire        spi_ack;
  wire        spi_err;
  wire        spi_irq;
  wire [31:0] spi_rdata;
  wire [31:0] xip_word = {spi_rdata[7:0], spi_rdata[15:8], spi_rdata[23:16], spi_rdata[31:24]};

  wire        wb_cyc = xip_active ? xip_wb_cyc : (normal_access && in_penable);
  wire        wb_stb = xip_active ? xip_wb_stb : normal_access;
  wire        wb_we  = xip_active ? xip_wb_we  : in_pwrite;
  wire [4:0]  wb_adr = xip_active ? xip_wb_adr : in_paddr[4:0];
  wire [31:0] wb_dat = xip_active ? xip_wb_dat : in_pwdata;
  wire [3:0]  wb_sel = xip_active ? xip_wb_sel : in_pstrb;

  assign spi_irq_out = spi_irq;

  assign in_pready = in_flash ? (xip_state == X_RESP && in_penable) : spi_ack;
  assign in_prdata = in_flash ? xip_rdata : spi_rdata;
  assign in_pslverr = in_flash ? xip_error : spi_err;

  always @(*) begin
    xip_wb_cyc = 1'b0;
    xip_wb_stb = 1'b0;
    xip_wb_we  = 1'b0;
    xip_wb_adr = 5'b0;
    xip_wb_dat = 32'b0;
    xip_wb_sel = 4'b1111;

    case (xip_state)
      X_W_TX0: begin
        xip_wb_cyc = 1'b1;
        xip_wb_stb = 1'b1;
        xip_wb_we  = 1'b1;
        xip_wb_adr = WB_TX0;
        xip_wb_dat = 32'b0;
      end
      X_W_TX1: begin
        xip_wb_cyc = 1'b1;
        xip_wb_stb = 1'b1;
        xip_wb_we  = 1'b1;
        xip_wb_adr = WB_TX1;
        xip_wb_dat = {8'h03, xip_addr[23:0]};
      end
      X_W_DIV: begin
        xip_wb_cyc = 1'b1;
        xip_wb_stb = 1'b1;
        xip_wb_we  = 1'b1;
        xip_wb_adr = WB_DIV;
        xip_wb_dat = 32'b0;
      end
      X_W_SS: begin
        xip_wb_cyc = 1'b1;
        xip_wb_stb = 1'b1;
        xip_wb_we  = 1'b1;
        xip_wb_adr = WB_SS;
        xip_wb_dat = 32'h1;
      end
      X_W_CTRL: begin
        xip_wb_cyc = 1'b1;
        xip_wb_stb = 1'b1;
        xip_wb_we  = 1'b1;
        xip_wb_adr = WB_CTRL;
        xip_wb_dat = CTRL_XIP;
      end
      X_R_RX0: begin
        xip_wb_cyc = 1'b1;
        xip_wb_stb = 1'b1;
        xip_wb_we  = 1'b0;
        xip_wb_adr = WB_RX0;
      end
      default: begin end
    endcase
  end

  always @(posedge clock) begin
    if (reset) begin
      xip_state <= X_IDLE;
      xip_addr <= 32'b0;
      xip_rdata <= 32'b0;
      xip_error <= 1'b0;
    end else begin
      case (xip_state)
        X_IDLE: begin
          if (xip_start) begin
            xip_addr <= {8'b0, in_paddr[23:2], 2'b0};
            xip_rdata <= 32'b0;
            xip_error <= in_pwrite;
            xip_state <= in_pwrite ? X_RESP : X_W_TX0;
          end
        end
        X_W_TX0:    if (spi_ack) xip_state <= X_W_TX1;
        X_W_TX1:    if (spi_ack) xip_state <= X_W_DIV;
        X_W_DIV:    if (spi_ack) xip_state <= X_W_SS;
        X_W_SS:     if (spi_ack) xip_state <= X_W_CTRL;
        X_W_CTRL:   if (spi_ack) xip_state <= X_WAIT_IRQ;
        X_WAIT_IRQ: if (spi_irq) xip_state <= X_R_RX0;
        X_R_RX0: begin
          if (spi_ack) begin
            xip_rdata <= xip_word;
            xip_state <= X_RESP;
          end
        end
        X_RESP: begin
          if (in_psel && in_penable) xip_state <= X_IDLE;
        end
        default: xip_state <= X_IDLE;
      endcase
    end
  end

  spi_top u0_spi_top (
    .wb_clk_i(clock),
    .wb_rst_i(reset),
    .wb_adr_i(wb_adr),
    .wb_dat_i(wb_dat),
    .wb_dat_o(spi_rdata),
    .wb_sel_i(wb_sel),
    .wb_we_i (wb_we),
    .wb_stb_i(wb_stb),
    .wb_cyc_i(wb_cyc),
    .wb_ack_o(spi_ack),
    .wb_err_o(spi_err),
    .wb_int_o(spi_irq),

    .ss_pad_o(spi_ss),
    .sclk_pad_o(spi_sck),
    .mosi_pad_o(spi_mosi),
    .miso_pad_i(spi_miso)
  );

endmodule
