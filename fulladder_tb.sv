module fulladder4_tb;

logic [3:0] a, b, sum;
logic cin, cout;
logic [4:0] expected;

fulladder4 dut (
  .a(a), .b(b), .cin(cin), .sum(sum), .cout(cout)
);

function automatic logic [4:0] calc_expected(
  input logic [3:0] calc_a,
  input logic [3:0] calc_b,
  input logic calc_cin
);
  calc_expected = calc_a + calc_b + calc_cin;
endfunction

task automatic check_outputs(string test_name);
begin
  expected = calc_expected(a, b, cin);

  if ({cout, sum} !== expected) begin
    $error(
      "%s failed: a=%0d b=%0d cin=%0b => sum=%0d cout=%0b, expected sum=%0d cout=%0b",
      test_name,
      a,
      b,
      cin,
      sum,
      cout,
      expected[3:0],
      expected[4]
    );
  end
  else begin
    $display(
      "%s passed: a=%0d b=%0d cin=%0b => sum=%0d cout=%0b",
      test_name,
      a,
      b,
      cin,
      sum,
      cout
    );
  end
end
endtask

task automatic drive(
  input logic [3:0] next_a,
  input logic [3:0] next_b,
  input logic next_cin,
  input bit update_a = 1'b1,
  input bit update_b = 1'b1,
  input bit update_cin = 1'b1,
  input time wait_after = 10
);
begin
  if (update_a) begin
    a = next_a;
  end

  if (update_b) begin
    b = next_b;
  end

  if (update_cin) begin
    cin = next_cin;
  end

  #wait_after;
end
endtask

task automatic run_directed_test(
  input string test_name,
  input logic [3:0] test_a,
  input logic [3:0] test_b,
  input logic test_cin,
  input bit update_a = 1'b1,
  input bit update_b = 1'b1,
  input bit update_cin = 1'b1,
  input time wait_after = 10
);
begin
  drive(test_a, test_b, test_cin, update_a, update_b, update_cin, wait_after);
  check_outputs(test_name);
end
endtask

task automatic run_corner_tests;
begin
  run_directed_test("corner_zero", 4'd0, 4'd0, 1'b0);
  run_directed_test("corner_cin_only", 4'd0, 4'd0, 1'b1);
  run_directed_test("corner_max_no_cin", 4'd15, 4'd15, 1'b0);
  run_directed_test("corner_max_with_cin", 4'd15, 4'd15, 1'b1);
  run_directed_test("corner_single_bit", 4'd8, 4'd8, 1'b0);
end
endtask

task automatic run_random_tests(input int test_count);
  int test_idx;
  logic [3:0] rand_a;
  logic [3:0] rand_b;
  logic rand_cin;
begin
  for (test_idx = 0; test_idx < test_count; test_idx++) begin
    rand_a = $urandom_range(0, 15);
    rand_b = $urandom_range(0, 15);
    rand_cin = $urandom_range(0, 1);

    run_directed_test($sformatf("random_%0d", test_idx), rand_a, rand_b, rand_cin, 1'b1, 1'b1, 1'b1, 5);
  end
end
endtask

initial begin
  a = 0;
  b = 0;
  cin = 0;

  run_directed_test("directed_init", 4'd0, 4'd0, 1'b0);
  run_directed_test("directed_cin_toggle", 4'd0, 4'd0, 1'b1, 1'b0, 1'b0, 1'b1);
  run_directed_test("directed_b_change", 4'd0, 4'd1, 1'b1, 1'b0, 1'b1, 1'b0);
  run_directed_test("directed_cin_drop", 4'd0, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1, 15);
  run_directed_test("directed_a_change", 4'd1, 4'd1, 1'b0, 1'b1, 1'b0, 1'b0);
  run_directed_test("directed_b_clear", 4'd1, 4'd0, 1'b0, 1'b0, 1'b1, 1'b0);
  run_directed_test("directed_cin_set", 4'd1, 4'd0, 1'b1, 1'b0, 1'b0, 1'b1);
  run_directed_test("directed_all_mix", 4'd1, 4'd1, 1'b1, 1'b0, 1'b1, 1'b0, 20);

  run_corner_tests();
  run_random_tests(20);

  $finish;
end

endmodule