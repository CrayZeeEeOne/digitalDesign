module gpio_logic (
    input  logic        clk,
    input  logic        rst,

    input  logic        wr_en,
    input  logic [31:0] wr_data,

    output logic [31:0] rd_data,
    output logic        led
);

    logic [31:0] gpio_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            gpio_reg <= 32'b0;
        end else begin
            if (wr_en) begin
                gpio_reg <= wr_data;
            end
        end
    end

    assign led     = gpio_reg[0];
    assign rd_data = gpio_reg;

endmodule
