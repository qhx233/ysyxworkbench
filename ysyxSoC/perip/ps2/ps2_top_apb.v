module ps2_top_apb(
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

  input         ps2_clk,
  input         ps2_data
);

  wire apb_fire = in_psel & in_penable;
  wire do_read = apb_fire & ~in_pwrite;
  wire addr_data = in_paddr[2:0] == 3'h0;

  reg [2:0] ps2_clk_sync;
  reg [1:0] ps2_data_sync;
  wire ps2_clk_fall = ps2_clk_sync[2:1] == 2'b10;
  wire ps2_data_s = ps2_data_sync[1];

  reg [3:0] bit_cnt;
  reg [7:0] shift;
  reg [7:0] fifo [0:7];
  reg [2:0] rd_ptr;
  reg [2:0] wr_ptr;
  reg [3:0] fifo_count;
`ifdef PS2_DEBUG
  reg [3:0] empty_read_count;
`endif

  wire do_pop = do_read & addr_data & (fifo_count != 4'd0);
  wire do_push = ps2_clk_fall & frame_ok & (fifo_count != 4'd8);
  wire frame_ok = (bit_cnt == 4'd10) & ps2_data_s;

  assign in_pready = apb_fire;
  assign in_pslverr = 1'b0;
  assign in_prdata = addr_data && (fifo_count != 4'd0) ? {24'b0, fifo[rd_ptr]} : 32'b0;

  always @(posedge clock) begin
    if (reset) begin
      ps2_clk_sync <= 3'b111;
      ps2_data_sync <= 2'b11;
      bit_cnt <= 4'd0;
      shift <= 8'b0;
      rd_ptr <= 3'd0;
      wr_ptr <= 3'd0;
      fifo_count <= 4'd0;
`ifdef PS2_DEBUG
      empty_read_count <= 4'd0;
`endif
    end else begin
      ps2_clk_sync <= {ps2_clk_sync[1:0], ps2_clk};
      ps2_data_sync <= {ps2_data_sync[0], ps2_data};

      if (do_pop) begin
        rd_ptr <= rd_ptr + 3'd1;
`ifdef PS2_DEBUG
        $display("[PS2] read scancode=0x%02x count=%0d", fifo[rd_ptr], fifo_count);
`endif
      end
`ifdef PS2_DEBUG
      else if (do_read & addr_data) begin
        if (empty_read_count != 4'd8) begin
          $display("[PS2] read empty");
          empty_read_count <= empty_read_count + 4'd1;
        end
      end
`endif

      if (do_push) begin
        fifo[wr_ptr] <= shift;
        wr_ptr <= wr_ptr + 3'd1;
`ifdef PS2_DEBUG
        $display("[PS2] push scancode=0x%02x count=%0d", shift, fifo_count);
`endif
      end

      case ({do_push, do_pop})
        2'b10: fifo_count <= fifo_count + 4'd1;
        2'b01: fifo_count <= fifo_count - 4'd1;
        default: begin end
      endcase

      if (ps2_clk_fall) begin
        case (bit_cnt)
          4'd0: begin
            if (!ps2_data_s) begin
              bit_cnt <= 4'd1;
            end
          end
          4'd1, 4'd2, 4'd3, 4'd4,
          4'd5, 4'd6, 4'd7, 4'd8: begin
            shift <= {ps2_data_s, shift[7:1]};
            bit_cnt <= bit_cnt + 4'd1;
          end
          4'd9: begin
            bit_cnt <= 4'd10;
          end
          4'd10: begin
            bit_cnt <= 4'd0;
          end
          default: begin
            bit_cnt <= 4'd0;
          end
        endcase
      end
    end
  end

  wire unused = |{in_pprot, in_pwdata, in_pstrb};

endmodule
