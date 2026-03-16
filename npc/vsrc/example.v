/*module example(
    input a,
    input b,
    output f
);
    assign f = a ^ b;
endmodule*/

module example(
    input clk,
    input rst,
    output reg [7:0] led
);
    reg [31:0] count;
    always @(posedge clk) begin
        if(rst) begin
            count <= 32'd0;
            led <= 8'b00000001;
        end else begin
            if(count == 32'd50000000) begin
                count <= 32'd0;
                led <= {led[6:0], led[7]};
            end else begin
                count <= count + 1;
            end
        end
        
    end
endmodule