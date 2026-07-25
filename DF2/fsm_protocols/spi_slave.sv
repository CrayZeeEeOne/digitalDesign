module spi_slave (
  input logic start, mosi, cs, clk, sck, reset,
  output logic miso, done
);
  parameter N = 4; 

  reg [N-1:0] in_reg;

  always_ff @(posedge clk, posedge reset) begin
    if (reset) begin
      miso = 0;
      in_reg[N] = mosi[0];
    end
    else if (~cs) begin
      in_reg[N] = mosi[0];
      in_reg = in_reg >> 1;
      miso = in_reg[0];
    end
  end

endmodule