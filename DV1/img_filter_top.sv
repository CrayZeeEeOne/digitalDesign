//==============================================================================
// img_filter_top -- модуль обробки зображення нелінійними фільтрами 3x3.
//
// Конвеєр:
//   axis_slave (рег.) --> filter_core (комб.) --> axis_master (рег.)
//
// Латентність: 2 такти. Пропускна здатність: 1 вікно за такт.
// Backpressure проходить наскрізь: i_axis_out_tready -> o_axis_in_tready
// (два рівні логіки, без комбінаційного шляху TVALID -> TREADY).
//==============================================================================
module img_filter_top #(
  parameter int DATA_BW      = 8,
  parameter int WINDOW_SIZE  = 9,
  localparam int IN_TDATA_BW = WINDOW_SIZE * DATA_BW
)(
  input  logic                   i_clk,
  input  logic                   i_rstn,

  input  logic [1:0]             i_config_select,

  // вхідний AXI4-Stream (вікно 3x3)
  input  logic                   i_axis_in_tvalid,
  output logic                   o_axis_in_tready,
  input  logic [IN_TDATA_BW-1:0] i_axis_in_tdata,

  // вихідний AXI4-Stream (оброблений піксель)
  output logic                   o_axis_out_tvalid,
  input  logic                   i_axis_out_tready,
  output logic [DATA_BW-1:0]     o_axis_out_tdata
);

  logic [IN_TDATA_BW-1:0] s1_win;
  logic [1:0]             s1_cfg;
  logic                   s1_valid;
  logic                   s1_ready;

  logic [DATA_BW-1:0]     core_pixel;

  //--------------------------------------------------------------------------
  axis_slave #(
    .DATA_BW      (DATA_BW),
    .WINDOW_SIZE  (WINDOW_SIZE)
  ) u_slave (
    .clk             (i_clk),
    .rstn            (i_rstn),
    .i_axis_tvalid   (i_axis_in_tvalid),
    .o_axis_tready   (o_axis_in_tready),
    .i_axis_tdata    (i_axis_in_tdata),
    .i_config_select (i_config_select),
    .o_win           (s1_win),
    .o_cfg           (s1_cfg),
    .o_valid         (s1_valid),
    .i_ready         (s1_ready)
  );

  //--------------------------------------------------------------------------
  filter_core #(
    .DATA_BW     (DATA_BW),
    .WINDOW_SIZE (WINDOW_SIZE)
  ) u_core (
    .i_win           (s1_win),
    .i_config_select (s1_cfg),
    .o_pixel         (core_pixel)
  );

  //--------------------------------------------------------------------------
  axis_master #(
    .DATA_BW (DATA_BW)
  ) u_master (
    .clk             (i_clk),
    .rstn            (i_rstn),
    .i_pixel         (core_pixel),
    .i_valid         (s1_valid),
    .o_ready         (s1_ready),
    .o_axis_tvalid   (o_axis_out_tvalid),
    .i_axis_tready   (i_axis_out_tready),
    .o_axis_tdata    (o_axis_out_tdata)
  );

endmodule
