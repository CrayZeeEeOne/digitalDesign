//==============================================================================
// iq_stream_top -- Verilog-2001 обгортка iq_stream_regs для IP Integrator.
//
// Імена портів за конвенцією Xilinx, тому Vivado сам згортає їх у
// S_AXI (AXI4-Lite) і M_AXIS (AXI-Stream). Логіки тут немає.
//==============================================================================
module iq_stream_top #(
  parameter integer C_S_AXI_ADDR_WIDTH = 5,
  parameter integer FIFO_DEPTH         = 1024
)(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:M_AXIS, ASSOCIATED_RESET s_axi_aresetn" *)
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

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
  output wire                          m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
  input  wire                          m_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
  output wire [31:0]                   m_axis_tdata
);

  iq_stream_regs #(
    .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
    .FIFO_DEPTH         (FIFO_DEPTH)
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
    .m_axis_tvalid (m_axis_tvalid), .m_axis_tready (m_axis_tready),
    .m_axis_tdata  (m_axis_tdata)
  );

endmodule
