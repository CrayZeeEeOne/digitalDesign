module fulladder4_tb;

logic [3:0] a, b, sum;
logic cin, cout;

fulladder4 dut (
  .a(a), .b(b), .cin(cin),
  .sum(sum), .cout(cout)
);

initial begin
  a = 0;
  b = 0;
  cin = 0;
  #10;

  cin = 1;
  #10;

  b = 1;
  #10;

  cin = 0;
  #10;

  a = 1;
  #10;

  b = 0;
  #10;

  cin = 1;
  #10;

  b = 1;
  #10;

  $finish;
end

endmodule