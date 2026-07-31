`timescale 1ns/1ps

module axi_master_tb;

  parameter N = 8;

  logic clk;
  logic n_rst;
  logic ready;

  logic valid;
  logic [N-1:0] data;

  axi_master #(
    .N(N)
  ) dut (
    .clk(clk),
    .n_rst(n_rst),
    .ready(ready),
    .valid(valid),
    .data(data)
  );

  // Clock
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // Stimulus
  initial begin

    n_rst = 0;
    ready = 1;

    #20;
    n_rst = 1;

    // Майстер чекає ready
    #20;
    ready = 0;

    // Один такт handshake
    #10;
    ready = 0;

    #40;

    $finish;
  end

  initial begin
    $monitor("T=%0t rst=%b ready=%b valid=%b data=%h state=%0d",
              $time,
              n_rst,
              ready,
              valid,
              data,
              dut.current_state);
  end

endmodule