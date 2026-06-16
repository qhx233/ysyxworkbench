module bitrev (
  input  sck,
  input  ss,
  input  mosi,
  output miso
);
  reg [3:0] bit_count;
  reg [7:0] request;
  reg miso_reg;

  wire [7:0] response = {
    request[0], request[1], request[2], request[3],
    request[4], request[5], request[6], request[7]
  };

  assign miso = ss ? 1'b1 : miso_reg;

  always @(posedge sck or posedge ss) begin
    if (ss) begin
      bit_count <= 4'd0;
      request <= 8'd0;
    end else begin
      if (bit_count < 4'd8) begin
        request <= {request[6:0], mosi};
      end
      bit_count <= bit_count + 4'd1;
    end
  end

  always @(negedge sck or posedge ss) begin
    if (ss) begin
      miso_reg <= 1'b1;
    end else begin
      case (bit_count)
        4'd8: miso_reg <= response[7];
        4'd9: miso_reg <= response[6];
        4'd10: miso_reg <= response[5];
        4'd11: miso_reg <= response[4];
        4'd12: miso_reg <= response[3];
        4'd13: miso_reg <= response[2];
        4'd14: miso_reg <= response[1];
        4'd15: miso_reg <= response[0];
        default: miso_reg <= 1'b1;
      endcase
    end
  end
endmodule
