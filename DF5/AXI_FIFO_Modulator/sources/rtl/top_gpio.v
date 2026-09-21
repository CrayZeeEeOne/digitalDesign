module top_gpio (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [3:0]  s_axi_awaddr,
    input  wire       s_axi_awvalid,
    output wire       s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [3:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire        led
);

    reg         gpio_wr_en;
    reg [31:0]  gpio_wr_data;

    wire [31:0] gpio_rd_data;

    reg         bvalid_reg;
    reg [1:0]   bresp_reg;

    reg         rvalid_reg;
    reg [31:0]  rdata_reg;
    reg [1:0]   rresp_reg;

    assign s_axi_awready = !bvalid_reg;
    assign s_axi_wready  = !bvalid_reg;

    assign s_axi_bvalid  = bvalid_reg;
    assign s_axi_bresp   = bresp_reg;

    assign s_axi_arready = !rvalid_reg;

    assign s_axi_rvalid  = rvalid_reg;
    assign s_axi_rdata   = rdata_reg;
    assign s_axi_rresp   = rresp_reg;

    gpio_logic gpio_i (
        .clk     (s_axi_aclk),
        .rst     (!s_axi_aresetn),
        .wr_en   (gpio_wr_en),
        .wr_data (gpio_wr_data),
        .rd_data (gpio_rd_data),
        .led     (led)
    );
    
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin

            gpio_wr_en  <= 1'b0;
            gpio_wr_data <= 32'b0;

            bvalid_reg <= 1'b0;
            bresp_reg  <= 2'b00;

            rvalid_reg <= 1'b0;
            rdata_reg  <= 32'b0;
            rresp_reg  <= 2'b00;

        end else begin

            gpio_wr_en <= 1'b0;

            if (s_axi_awvalid &&
                s_axi_awready &&
                s_axi_wvalid &&
                s_axi_wready) begin

                if (s_axi_awaddr == 4'h0) begin

                    gpio_wr_en   <= 1'b1;
                    gpio_wr_data <= s_axi_wdata;

                    bresp_reg <= 2'b00;

                end else begin

                    bresp_reg <= 2'b10;
                end

                bvalid_reg <= 1'b1;
            end

            if (bvalid_reg && s_axi_bready) begin
                bvalid_reg <= 1'b0;
            end

            if (s_axi_arvalid && s_axi_arready) begin

                if (s_axi_araddr == 4'h0) begin

                    rdata_reg <= gpio_rd_data;
                    rresp_reg <= 2'b00;

                end else begin

                    rdata_reg <= 32'b0;
                    rresp_reg <= 2'b10;
                end

                rvalid_reg <= 1'b1;
            end

            if (rvalid_reg && s_axi_rready) begin
                rvalid_reg <= 1'b0;
            end

        end
    end

endmodule
