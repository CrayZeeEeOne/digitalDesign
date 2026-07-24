module register (
  input clk, reset,
  input logic [3:0] d,
  output logic [3:0] q
);

always_ff @(posedge clk) begin 
  if(reset)
    q <= 0;
  else
    q <= d;
end

endmodule