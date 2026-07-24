module and_gate_tb;

  //tb signals
  logic a, b, y; 

  //dut
  and_gate dut (
    .a(a), .b(b), .y(y)
  );

  initial begin
  a = 0;
  b = 0;
  #10;

  a = 1;
  b = 0;
  #10;

  a = 0;
  b = 1;
  #10;

  a = 1;
  b = 1;
  #10;

  $finish;
  end

endmodule