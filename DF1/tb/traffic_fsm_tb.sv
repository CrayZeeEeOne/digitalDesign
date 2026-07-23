`timescale 1ns/1ps

module traffic_fsm_tb;

    //==================================================
    // Testbench signals
    //==================================================
    logic clk;
    logic reset;
    logic Ta;
    logic Tb;

    logic [1:0] La;
    logic [1:0] Lb;

    // Для спостереження за станами
    logic [1:0] current_state;
    logic [1:0] next_state;

    //==================================================
    // Design Under Test
    //==================================================
    traffic_fsm dut (
        .clk   (clk),
        .reset (reset),
        .Ta    (Ta),
        .Tb    (Tb),
        .La    (La),
        .Lb    (Lb)
    );

    // Підключення внутрішніх сигналів DUT
    assign current_state = dut.current_state;
    assign next_state    = dut.next_state;

    //==================================================
    // Clock generation
    //==================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //==================================================
    // Monitor
    //==================================================
    initial begin
        $display("Time\tCur\tNext\tTa Tb\tLa Lb");
        $monitor("%0t\t%0d\t%0d\t%b  %b\t%b %b",
                 $time,
                 current_state,
                 next_state,
                 Ta,
                 Tb,
                 La,
                 Lb);
    end

    //==================================================
    // Test sequence
    //==================================================
    initial begin

        reset = 0;
        Ta    = 1;
        Tb    = 1;

        #12;
        reset = 1;

        #20;

        Ta = 0;
        #10;

        Ta = 1;
        #10;

        #20;

        Tb = 0;
        #10;

        Tb = 1;
        #10;

        Ta = 0;
        #10;

        Ta = 1;
        #10;

        Tb = 0;
        #10;

        Tb = 1;
        #20;

        $finish;
    end

endmodule