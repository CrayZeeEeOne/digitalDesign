module d_latch (
  input logic clk, d,
  output logic q, qn

);
  logic r, s;

  assign r = clk & ~d;
  assign s = clk & d;

  assign q = ~(r | qn);
  assign qn = ~(s | q);

endmodule