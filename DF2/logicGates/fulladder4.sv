module fulladder4 (
  input logic [3:0] a, b,
  input cin,
  output logic [3:0] sum,
  output cout
);
  wire s1, s2, ab;

  assign s1 = a ^ b;
  assign ab = a & b;
  assign sum = s1 ^ cin;
  assign s2 = cin & s1;
  assign cout = ab | s2;
endmodule