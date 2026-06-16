module sdram(
  input        clk,
  input        cke,
  input [ 1:0] cs,
  input        ras,
  input        cas,
  input        we,
  input [12:0] a,
  input [ 1:0] ba,
  input [ 3:0] dqm,
  inout [31:0] dq
);

  sdram_x16 u_sdram_r0_lo (
    .clk(clk),
    .cke(cke),
    .cs(cs[0]),
    .ras(ras),
    .cas(cas),
    .we(we),
    .a(a),
    .ba(ba),
    .dqm(dqm[1:0]),
    .dq(dq[15:0])
  );

  sdram_x16 u_sdram_r0_hi (
    .clk(clk),
    .cke(cke),
    .cs(cs[0]),
    .ras(ras),
    .cas(cas),
    .we(we),
    .a(a),
    .ba(ba),
    .dqm(dqm[3:2]),
    .dq(dq[31:16])
  );

  sdram_x16 u_sdram_r1_lo (
    .clk(clk),
    .cke(cke),
    .cs(cs[1]),
    .ras(ras),
    .cas(cas),
    .we(we),
    .a(a),
    .ba(ba),
    .dqm(dqm[1:0]),
    .dq(dq[15:0])
  );

  sdram_x16 u_sdram_r1_hi (
    .clk(clk),
    .cke(cke),
    .cs(cs[1]),
    .ras(ras),
    .cas(cas),
    .we(we),
    .a(a),
    .ba(ba),
    .dqm(dqm[3:2]),
    .dq(dq[31:16])
  );

endmodule

module sdram_x16(
  input        clk,
  input        cke,
  input        cs,
  input        ras,
  input        cas,
  input        we,
  input [12:0] a,
  input [ 1:0] ba,
  input [ 1:0] dqm,
  inout [15:0] dq
);

  localparam CMD_LOAD_MODE = 4'b0000;
  localparam CMD_AUTO_REF  = 4'b0001;
  localparam CMD_PRECHG    = 4'b0010;
  localparam CMD_ACTIVE    = 4'b0011;
  localparam CMD_WRITE     = 4'b0100;
  localparam CMD_READ      = 4'b0101;

  localparam COL_W   = 9;
  localparam ROW_W   = 13;
  localparam BANKS   = 4;
  localparam MEM_AW  = 24;
  localparam MEM_SZ  = 1 << MEM_AW;

  reg [15:0] mem [0:MEM_SZ-1];
  reg [ROW_W-1:0] active_row [0:BANKS-1];
  reg [2:0] burst_len;
  reg [1:0] cas_latency;

  reg [15:0] dq_out;
  reg        dq_oe;
  assign dq = dq_oe ? dq_out : 16'bz;

  wire [3:0] cmd = {cs, ras, cas, we};
  wire [15:0] dq_in = dq;

  reg [MEM_AW-1:0] read_addr;
  reg [1:0]        read_delay;
  reg              read_pending;
  reg              read_second_valid;
  reg              read_drive_valid;
  reg [MEM_AW-1:0] write_next_addr;
  reg              write_burst_valid;

  integer i;
  initial begin
    burst_len = 3'd2;
    cas_latency = 2'd2;
    dq_out = 16'h0;
    dq_oe = 1'b0;
    write_next_addr = {MEM_AW{1'b0}};
    write_burst_valid = 1'b0;
    read_addr = {MEM_AW{1'b0}};
    read_delay = 2'b0;
    read_pending = 1'b0;
    read_second_valid = 1'b0;
    read_drive_valid = 1'b0;
    for (i = 0; i < BANKS; i = i + 1) begin
      active_row[i] = {ROW_W{1'b0}};
    end
  end

  function [MEM_AW-1:0] make_addr;
    input [1:0] bank;
    input [ROW_W-1:0] row;
    input [COL_W-1:0] col;
    begin
      make_addr = {row, bank, col};
    end
  endfunction

  function [2:0] decode_burst_len;
    input [2:0] mode_bl;
    begin
      case (mode_bl)
        3'b000: decode_burst_len = 3'd1;
        3'b001: decode_burst_len = 3'd2;
        3'b010: decode_burst_len = 3'd4;
        3'b011: decode_burst_len = 3'd0;
        default: decode_burst_len = 3'd2;
      endcase
    end
  endfunction

  task write_half;
    input [MEM_AW-1:0] addr;
    input [15:0] data;
    input [1:0] mask;
    begin
      if (!mask[0]) mem[addr][7:0]  = data[7:0];
      if (!mask[1]) mem[addr][15:8] = data[15:8];
    end
  endtask

  always @(posedge clk) begin
    dq_oe <= read_drive_valid;
    read_drive_valid <= 1'b0;

    if (read_pending) begin
      if (read_delay != 2'b0) begin
        read_delay <= read_delay - 1'b1;
      end else begin
        dq_out <= mem[read_addr];
        read_addr <= read_addr + 1'b1;
        read_pending <= 1'b0;
        read_drive_valid <= 1'b1;
        read_second_valid <= (burst_len != 3'd1);
      end
    end else if (read_second_valid) begin
      dq_out <= mem[read_addr];
      read_drive_valid <= 1'b1;
      read_second_valid <= 1'b0;
    end

    if (cke) begin
      if (write_burst_valid) begin
        write_half(write_next_addr, dq_in, dqm);
        write_next_addr <= write_next_addr + 1'b1;
        write_burst_valid <= 1'b0;
      end

      case (cmd)
        CMD_LOAD_MODE: begin
          burst_len <= decode_burst_len(a[2:0]);
          cas_latency <= a[6:4] == 3'd3 ? 2'd3 : 2'd2;
        end

        CMD_AUTO_REF,
        CMD_PRECHG: begin
          write_burst_valid <= 1'b0;
        end

        CMD_ACTIVE: begin
          active_row[ba] <= a;
        end

        CMD_WRITE: begin
          write_half(make_addr(ba, active_row[ba], a[COL_W-1:0]), dq_in, dqm);
          write_next_addr <= make_addr(ba, active_row[ba], a[COL_W-1:0]) + 1'b1;
          write_burst_valid <= (burst_len != 3'd1);
        end

        CMD_READ: begin
          read_addr <= make_addr(ba, active_row[ba], a[COL_W-1:0]);
          read_delay <= (cas_latency > 2'd1) ? (cas_latency - 2'd2) : 2'd0;
          read_pending <= 1'b1;
          read_second_valid <= 1'b0;
        end

        default: begin
        end
      endcase
    end
  end

endmodule
