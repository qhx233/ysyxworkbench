module psram(
  input sck,
  input ce_n,
  inout [3:0] dio
);

  localparam MEM_SIZE = 4 * 1024 * 1024;

  localparam [7:0] CMD_ENTER_QPI  = 8'h35;
  localparam [7:0] CMD_QIO_READ  = 8'heb;
  localparam [7:0] CMD_QIO_WRITE = 8'h38;

  localparam [1:0] ST_CMD  = 2'd0;
  localparam [1:0] ST_ADDR = 2'd1;
  localparam [1:0] ST_WAIT = 2'd2;
  localparam [1:0] ST_DATA = 2'd3;

  reg [7:0] mem [0:MEM_SIZE-1];

  reg [1:0] state;
  reg [7:0] cmd;
  reg [23:0] addr;
  reg [7:0] counter;
  reg [31:0] rdata;
  reg [3:0] dout;
  reg douten;
  reg qpi_mode;

  wire [21:0] mem_addr = addr[21:0];
  wire [23:0] next_addr = {addr[19:0], dio};
  wire [3:0] data_nibble =
      (counter == 8'd15) ? rdata[7:4]   :
      (counter == 8'd16) ? rdata[3:0]   :
      (counter == 8'd17) ? rdata[15:12] :
      (counter == 8'd18) ? rdata[11:8]  :
      (counter == 8'd19) ? rdata[23:20] :
      (counter == 8'd20) ? rdata[19:16] :
      (counter == 8'd21) ? rdata[31:28] :
                           rdata[27:24];

  assign dio = douten ? dout : 4'bz;

  integer i;
  initial begin
    qpi_mode = 1'b0;
    for (i = 0; i < MEM_SIZE; i = i + 1) begin
      mem[i] = 8'b0;
    end
  end

  always @(posedge sck or posedge ce_n) begin
    if (ce_n) begin
      state <= ST_CMD;
      cmd <= 8'b0;
      addr <= 24'b0;
      counter <= 8'b0;
      rdata <= 32'b0;
    end else begin
      counter <= counter + 8'b1;

      case (state)
        ST_CMD: begin
          if (qpi_mode) begin
            cmd <= {cmd[3:0], dio};
            if (counter == 8'd1) begin
              state <= ST_ADDR;
            end
          end else begin
            cmd <= {cmd[6:0], dio[0]};
            if (counter == 8'd7) begin
              if ({cmd[6:0], dio[0]} == CMD_ENTER_QPI) begin
                qpi_mode <= 1'b1;
              end else begin
                state <= ST_ADDR;
              end
            end
          end
        end
        ST_ADDR: begin
          addr <= next_addr;
          if ((qpi_mode && counter == 8'd7) || (!qpi_mode && counter == 8'd13)) begin
            if (cmd == CMD_QIO_READ) begin
              state <= ST_WAIT;
              rdata <= {
                mem[{next_addr[21:2], 2'b0} + 22'd3],
                mem[{next_addr[21:2], 2'b0} + 22'd2],
                mem[{next_addr[21:2], 2'b0} + 22'd1],
                mem[{next_addr[21:2], 2'b0}]
              };
            end else if (cmd == CMD_QIO_WRITE) begin
              state <= ST_DATA;
            end
          end
        end
        ST_WAIT: begin
          if ((qpi_mode && counter == 8'd13) || (!qpi_mode && counter == 8'd19)) begin
            state <= ST_DATA;
          end
        end
        ST_DATA: begin
          if (cmd == CMD_QIO_WRITE) begin
            case (counter[0])
              1'b0: begin
                mem[mem_addr] <= {dio, 4'b0};
              end
              1'b1: begin
                mem[mem_addr] <= {mem[mem_addr][7:4], dio};
                addr <= addr + 24'b1;
              end
            endcase
          end
        end
        default: state <= ST_CMD;
      endcase
    end
  end

  always @(*) begin
    dout = 4'b0;
    douten = 1'b0;
    if (!ce_n && state == ST_DATA && cmd == CMD_QIO_READ) begin
      dout = data_nibble;
      douten = 1'b1;
    end
  end

endmodule
