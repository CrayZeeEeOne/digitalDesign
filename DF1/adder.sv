module halfadder (
  input logic [31:0] a, b,
  output logic [31:0] sum,
  output logic carry
);
  assign sum = a ^ b;
  assign carry = a & b;
endmodule

module fulladder (
  input logic [31:0] a, b,
  input logic cin,
  output logic [31:0] s,
  output logic cout

);
  wire s1, ab; //a ^ b, a & b

  halfadder halfadd1 (
    .a(a), .b(b),
    .sum(s1), .carry(ab)
  );

  wire s2; // cin ^ (a ^ b)

  halfadder halfadd2 (
    .a(s1), .b(cin),
    .sum(s), .carry(s2)
  );

  assign cout = ab | s2;
endmodule