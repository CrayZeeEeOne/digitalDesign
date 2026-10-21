//==============================================================================
// dsp_top -- Verilog-2001 обгортка dsp_regs (увесь DSP у залізі: генератор,
// демодулятор, FFT/waterfall, захоплення) для IP Integrator.
// Порти за конвенцією Xilinx -> S_AXI (AXI4-Lite, 16 КБ) і S_AXIS (I/Q з iq_stream).
// Мапа регістрів -- у шапці dsp_regs.sv.
//==============================================================================
module dsp_top #(
  parameter integer C_S_AXI_ADDR_WIDTH = 14
)(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:S_AXIS, ASSOCIATED_RESET s_axi_aresetn" *)
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

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
  input  wire                          s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output wire                          s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input  wire [31:0]                   s_axis_tdata,

  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
  output wire                          irq
);

  dsp_regs #(
    .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH)
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
    .s_axis_tvalid (s_axis_tvalid), .s_axis_tready (s_axis_tready),
    .s_axis_tdata  (s_axis_tdata),
    .irq           (irq)
  );

endmodule
