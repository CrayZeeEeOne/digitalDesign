module mux2to1_tb;

  logic a, b, sel, y;

  mux2to1 dut (
    .a(a), .b(b), .sel(sel),
    .y(y)
  );

  initial begin
  a = 0;
  b = 0;
  sel = 0;
  #10;

  a = 1;
  #10;

  b = 1;
  #10;

  a = 0;
  #10;

  sel = 1;
  #10;

  b = 0;
  #10;

  a = 1;
  #10;

  b = 1;
  #10;

  $finish;
  end

endmodule