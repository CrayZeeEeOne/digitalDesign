`timescale 1ns/1ps

module spi_tb;

    parameter N = 4;

    logic clk;
    logic reset;
    logic start;

    logic cs;
    logic sck;
    logic mosi;
    logic miso;

    logic done_master;
    logic done_slave;

    logic [N-1:0] tx_master;

    //-------------------------------------------------
    // Clock
    //-------------------------------------------------

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------
    // DUT
    //-------------------------------------------------

    spi_master #(.N(N)) master (
        .clk(clk),
        .reset(reset),
        .start(start),
        .miso(miso),
        .data(tx_master),
        .mosi(mosi),
        .done(done_master),
        .sck(sck),
        .cs(cs)
    );

    spi_slave #(.N(N)) slave (
        .clk(clk),
        .reset(reset),
        .start(start),
        .mosi(mosi),
        .miso(miso),
        .sck(sck),
        .cs(cs),
        .done(done_slave)
    );

    //-------------------------------------------------
    // Stimulus
    //-------------------------------------------------

    initial begin

        reset = 1;
        start = 0;
        tx_master = 4'b1011;

        #20;
        reset = 0;

        #20;
        start = 1;

        #10;
        start = 0;

        wait(done_master);

        #50;

        $display("------------------------------");
        $display("MASTER TX = %b", tx_master);
        $display("SLAVE RX  = %b", slave.rx_shift_reg);
        $display("MASTER RX = %b", master.rx_shift_reg);
        $display("------------------------------");

        $finish;

    end

    //-------------------------------------------------
    // Monitor
    //-------------------------------------------------

    initial begin
        $monitor(
            "T=%0t  CS=%b SCK=%b MOSI=%b MISO=%b | M_STATE=%0d S_STATE=%0d | TX=%b RX=%b",
            $time,
            cs,
            sck,
            mosi,
            miso,
            master.current_state,
            slave.current_state,
            master.tx_shift_reg,
            slave.rx_shift_reg
        );
    end

endmodule