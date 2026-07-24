module counter (
  input clk, reset, enable,
  output logic [2:0] count
);
always_ff @(posedge clk) begin
  count <= 0;
  if (reset)
      count <= 0;
  else if (enable)
      count++;
end


endmodule