`timescale 1ns/1ps

module spi_master_tb;

    localparam N = 8;

    logic clk;
    logic reset;
    logic start;
    logic miso;

    logic [N-1:0] data;

    logic mosi;
    logic done;
    logic sck;
    logic cs;

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

    //-----------------------------
    // Clock 100 MHz
    //-----------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //-----------------------------
    // Stimulus
    //-----------------------------
    initial begin

        reset = 1;
        start = 0;
        miso  = 0;

        data = 8'b10101110;

        #20;
        reset = 0;

        #20;

    
        start = 1;

        #10;
        start = 0;

   
        #300;

        $finish;
    end

endmodule