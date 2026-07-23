module mux4to1 (
  input logic a, b, c, d, a1, b1, c1, d1,
  input logic [1:0] sel, sel1,
  output logic result, result1, low, high
);
  assign result = sel[1] ? (sel[0] ? d : c)
                         : (sel[0] ? b : a);

  // wire low, high; - не робіт, я хз чому
  mux2 lowmux (
    .a(a1), .b(b1), .sel(sel1[0]),
    .y(low)
  ); //mux2 lowmux (a1, b1, sel1[0], low);
  mux2 highmux (c1, d1, sel1[0], high);
  mux2 finalmux (low, high, sel1[1], result1);

endmodule

module mux2 (
  input logic a, b, sel,
  output y
);
  always_comb begin
    case(sel)
      0: y = a;
      1: y = b;
    endcase
  end
endmodule