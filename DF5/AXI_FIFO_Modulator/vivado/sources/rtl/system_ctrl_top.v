//==============================================================================
// system_ctrl_top -- Verilog-2001 Ð¾Ð±Ð³Ð¾Ñ€Ñ‚ÐºÐ° system_ctrl_regs Ð´Ð»Ñ IP Integrator.
//
// Ð„Ð´Ð¸Ð½Ð° Ð»Ð¾Ð³Ñ–ÐºÐ° Ñ‚ÑƒÑ‚ -- BUFG Ð½Ð° Ñ‚Ð°ÐºÑ‚Ñ– Ð´Ð»Ñ SD-SPI: Ñ€ÐµÐ³Ñ–ÑÑ‚Ñ€Ð¾Ð²Ð¸Ð¹ Ð²Ð¸Ñ…Ñ–Ð´ Ð´Ñ–Ð»ÑŒÐ½Ð¸ÐºÐ°
// ÑÑ‚Ð°Ñ” Ð³Ð»Ð¾Ð±Ð°Ð»ÑŒÐ½Ð¸Ð¼ Ñ‚Ð°ÐºÑ‚Ð¾Ð¼, ÑÐºÐ¸Ð¹ Ñ–Ð´Ðµ Ð½Ð° ext_spi_clk Ð±Ð»Ð¾ÐºÑƒ AXI Quad SPI.
//==============================================================================
module system_ctrl_top #(
  parameter integer C_S_AXI_ADDR_WIDTH = 6,
  parameter integer ACLK_HZ            = 100000000
)(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
  input  wire                          s_axi_aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                          s_axi_aresetn,

  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [2:0]                    s_axi_awprot,
  input  wire                          s_axi_awvalid,
  output wire                          s_axi_awready,
  input  wire [31:0]                   s_axi_wdata,
  input  wire [3:0]                    s_axi_wstrb,
  input  wire                          s_axi_wvalid,
  output wire                          s_axi_wready,
  output wire [1:0]                    s_axi_bresp,
  output wire                          s_axi_bvalid,
  input  wire                          s_axi_bready,
  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire [2:0]                    s_axi_arprot,
  input  wire                          s_axi_arvalid,
  output wire                          s_axi_arready,
  output wire [31:0]                   s_axi_rdata,
  output wire [1:0]                    s_axi_rresp,
  output wire                          s_axi_rvalid,
  input  wire                          s_axi_rready,

  input  wire                          btn1_n,     // KEY1, W22 (active-low)
  input  wire                          btn2_n,     // KEY2, Y21 (active-low)
  output wire                          led1,       // user LED0 (pin by board xdc)
  output wire                          led2,       // user LED1 (pin by board xdc)
  output wire                          sd_cs_n,    // SD_DATA3, AA21

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 spi_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "FREQ_HZ 50000000" *)
  output wire                          spi_clk     // -> axi_quad_spi.ext_spi_clk
);

  wire spi_clk_raw;
  wire [1:0] led;

  system_ctrl_regs #(
    .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
    .ACLK_HZ            (ACLK_HZ),
    .N_BTN              (2),
    .N_LED              (2)
  ) u_regs (
    .s_axi_aclk    (s_axi_aclk),    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),  .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid), .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),   .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),  .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),   .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),  .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid), .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),   .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),  .s_axi_rready  (s_axi_rready),
    .btn_n         ({btn2_n, btn1_n}),
    .led           (led),
    .sd_cs_n       (sd_cs_n),
    .spi_clk_raw   (spi_clk_raw)
  );

  assign led1 = led[0];
  assign led2 = led[1];

  // Ð“Ð»Ð¾Ð±Ð°Ð»ÑŒÐ½Ð¸Ð¹ Ð±ÑƒÑ„ÐµÑ€: Ñ–Ð½Ð°ÐºÑˆÐµ Vivado Ñ€Ð¾Ð·Ð²ÐµÐ´Ðµ Ñ‚Ð°ÐºÑ‚ Ð·Ð²Ð¸Ñ‡Ð°Ð¹Ð½Ð¾ÑŽ Ñ‚Ñ€Ð°ÑÐ¾ÑŽ Ñ–
  // Ð¿Ð¾ÑÐºÐ°Ñ€Ð¶Ð¸Ñ‚ÑŒÑÑ Ð½Ð° "clock on non-clock net".
  BUFG u_bufg (.I(spi_clk_raw), .O(spi_clk));

endmodule
