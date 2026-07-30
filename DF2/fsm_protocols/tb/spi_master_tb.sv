`timescale 1ns/1ps

module spi_master_tb;

    parameter N = 4;

    //==================================================
    // Testbench signals
    //==================================================
    logic clk;
    logic reset;
    logic start;
    logic miso;

    logic [N-1:0] data;

    logic mosi;
    logic done;
    logic sck;
    logic cs;

    //==================================================
    // DUT
    //==================================================
    spi_master #(
        .N(N)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .miso(miso),
        .data(data),
        .mosi(mosi),
        .done(done),
        .sck(sck),
        .cs(cs)
    );

    //==================================================
    // Clock generation (100 MHz)
    //==================================================
    initial clk = 0;
    always #5 clk = ~clk;

    //==================================================
    // Stimulus
    //==================================================
    initial begin

        reset = 1;
        start = 0;
        data  = 4'b1011;
        miso  = 0;

        #20;
        reset = 0;

        #20;
        start = 1;
        #10;
        start = 0;

        // Дані, які "надсилає" slave
        @(posedge sck) miso <= 1;
        @(posedge sck) miso <= 1;
        @(posedge sck) miso <= 0;
        @(posedge sck) miso <= 1;

    end

    //==================================================
    // Monitor
    //==================================================
    initial begin
        $monitor(
            "t=%0t  state=%s  cs=%b sck=%b mosi=%b miso=%b tx=%b rx=%b bit=%0d done=%b",
            $time,
            dut.current_state.name(),
            cs,
            sck,
            mosi,
            miso,
            dut.tx_shift_reg,
            dut.rx_shift_reg,
            dut.bit_index,
            done
        );
    end

    //==================================================
    // Finish
    //==================================================
    initial begin
        #500;
        $finish;
    end

endmodule