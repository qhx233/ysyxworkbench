module gpio_top_apb(
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

  output [15:0] gpio_out,
  input  [15:0] gpio_in,
  output [7:0]  gpio_seg_0,
  output [7:0]  gpio_seg_1,
  output [7:0]  gpio_seg_2,
  output [7:0]  gpio_seg_3,
  output [7:0]  gpio_seg_4,
  output [7:0]  gpio_seg_5,
  output [7:0]  gpio_seg_6,
  output [7:0]  gpio_seg_7
);

  reg [15:0] gpio_out_reg;
  reg [31:0] gpio_seg_reg;

  wire apb_fire = in_psel & in_penable;
  wire do_write = apb_fire & in_pwrite;
  wire [3:0] addr = in_paddr[3:0];
  wire unused = |{in_paddr[31:4], in_pprot};

  function [7:0] hex_to_seg_active_high;
    input [3:0] value;
    begin
      case (value)
        4'h0: hex_to_seg_active_high = 8'b11111100;
        4'h1: hex_to_seg_active_high = 8'b01100000;
        4'h2: hex_to_seg_active_high = 8'b11011010;
        4'h3: hex_to_seg_active_high = 8'b11110010;
        4'h4: hex_to_seg_active_high = 8'b01100110;
        4'h5: hex_to_seg_active_high = 8'b10110110;
        4'h6: hex_to_seg_active_high = 8'b10111110;
        4'h7: hex_to_seg_active_high = 8'b11100000;
        4'h8: hex_to_seg_active_high = 8'b11111110;
        4'h9: hex_to_seg_active_high = 8'b11110110;
        4'ha: hex_to_seg_active_high = 8'b11101110;
        4'hb: hex_to_seg_active_high = 8'b00111110;
        4'hc: hex_to_seg_active_high = 8'b10011100;
        4'hd: hex_to_seg_active_high = 8'b01111010;
        4'he: hex_to_seg_active_high = 8'b10011110;
        default: hex_to_seg_active_high = 8'b10001110;
      endcase
    end
  endfunction

  function [7:0] hex_to_seg;
    input [3:0] value;
    begin
      hex_to_seg = ~hex_to_seg_active_high(value);
    end
  endfunction

  assign gpio_out = gpio_out_reg;
  assign gpio_seg_0 = hex_to_seg(gpio_seg_reg[3:0]);
  assign gpio_seg_1 = hex_to_seg(gpio_seg_reg[7:4]);
  assign gpio_seg_2 = hex_to_seg(gpio_seg_reg[11:8]);
  assign gpio_seg_3 = hex_to_seg(gpio_seg_reg[15:12]);
  assign gpio_seg_4 = hex_to_seg(gpio_seg_reg[19:16]);
  assign gpio_seg_5 = hex_to_seg(gpio_seg_reg[23:20]);
  assign gpio_seg_6 = hex_to_seg(gpio_seg_reg[27:24]);
  assign gpio_seg_7 = hex_to_seg(gpio_seg_reg[31:28]);

  assign in_pready = apb_fire;
  assign in_pslverr = unused & 1'b0;
  assign in_prdata = addr == 4'h0 ? {16'b0, gpio_out_reg} :
                     addr == 4'h4 ? {16'b0, gpio_in} :
                     addr == 4'h8 ? gpio_seg_reg :
                                    32'b0;

  always @(posedge clock) begin
    if (reset) begin
      gpio_out_reg <= 16'b0;
      gpio_seg_reg <= 32'b0;
    end else if (do_write) begin
      if (addr == 4'h0) begin
        if (in_pstrb[0]) gpio_out_reg[7:0] <= in_pwdata[7:0];
        if (in_pstrb[1]) gpio_out_reg[15:8] <= in_pwdata[15:8];
      end else if (addr == 4'h8) begin
        if (in_pstrb[0]) gpio_seg_reg[7:0] <= in_pwdata[7:0];
        if (in_pstrb[1]) gpio_seg_reg[15:8] <= in_pwdata[15:8];
        if (in_pstrb[2]) gpio_seg_reg[23:16] <= in_pwdata[23:16];
        if (in_pstrb[3]) gpio_seg_reg[31:24] <= in_pwdata[31:24];
      end
    end
  end

endmodule
