module test (
  input logic clk,
  input logic [3:0] data,
  output logic mosi, sck, cs
);
  
  int i = 0;

  always_ff @(posedge clk) begin
    sck = 1;
    cs = 0;
    mosi = data[i];
    i++;
  end
  
endmodule
