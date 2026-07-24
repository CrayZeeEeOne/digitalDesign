module mux2to1 (
  input a, b, sel,
  output y
);

  assign y = sel ? b : a;
  // always_comb begin
  //   case(sel)
  //     0: y = a;
  //     1: y = b;
  //   endcase
  // end
endmodule