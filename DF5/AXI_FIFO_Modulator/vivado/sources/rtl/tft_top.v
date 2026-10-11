//==============================================================================
// tft_top -- Verilog-2001 обгортка навколо spi_tft_ctrl (SystemVerilog).
//
// Потрібна для IP Integrator: порти плоскі wire, імена за конвенцією Xilinx,
// тому Vivado згорне їх в AXI4-Lite інтерфейс і Connection Automation
// спрацює автоматично. Ніякої логіки тут немає.
//
// Порти дисплея скалярні -> у .xdc пишуться без квадратних дужок.
// Файл зберігати як .v (File Type: Verilog).
//==============================================================================
module tft_top #(
  parameter integer C_S_AXI_ADDR_WIDTH = 5,
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer FIFO_DEPTH         = 16,
  parameter [31:0]  ID_VALUE           = 32'h5F778901
)(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
  input  wire                              s_axi_aclk,

  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                              s_axi_aresetn,

  //------------------------------------------------------ AXI4-Lite, запис
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
  input  wire [2:0]                        s_axi_awprot,
  input  wire                              s_axi_awvalid,
  output wire                              s_axi_awready,

  input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
  input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
  input  wire                              s_axi_wvalid,
  output wire                              s_axi_wready,

  output wire [1:0]                        s_axi_bresp,
  output wire                              s_axi_bvalid,
  input  wire                              s_axi_bready,

  //---------------------------------------------------- AXI4-Lite, читання
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
  input  wire [2:0]                        s_axi_arprot,
  input  wire                              s_axi_arvalid,
  output wire                              s_axi_arready,

  output wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
  output wire [1:0]                        s_axi_rresp,
  output wire                              s_axi_rvalid,
  input  wire                              s_axi_rready,

  //------------------------------------------------------------- на плату
  output wire                              tft_sclk,
  output wire                              tft_mosi,
  input  wire                              tft_miso,
  output wire                              tft_cs_n,
  output wire                              tft_dc,
  output wire                              tft_rst_n,
  output wire                              tft_blk
);

  spi_tft_ctrl #(
    .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
    .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
    .FIFO_DEPTH         (FIFO_DEPTH),
    .ID_VALUE           (ID_VALUE)
  ) u_spi (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),

    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),

    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),

    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),

    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),

    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),

    .tft_sclk      (tft_sclk),
    .tft_mosi      (tft_mosi),
    .tft_miso      (tft_miso),
    .tft_cs_n      (tft_cs_n),
    .tft_dc        (tft_dc),
    .tft_rst_n     (tft_rst_n),
    .tft_blk       (tft_blk)
  );

endmodule
