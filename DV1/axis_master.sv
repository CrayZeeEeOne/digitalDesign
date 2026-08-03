//==============================================================================
// axis_master -- вихідний канал AXI4-Stream (спрощений).
//
// Реєструє піксель з filter_core і віддає його назовні. Це другий ступінь
// конвеєра; він же ізолює o_axis_tvalid/tdata від комбінаційної логіки ядра.
//==============================================================================
module axis_master #(
  parameter int DATA_BW = 8
)(
  input  logic               clk,
  input  logic               rstn,

  // внутрішній канал від filter_core
  input  logic [DATA_BW-1:0] i_pixel,
  input  logic               i_valid,
  output logic               o_ready,

  // AXI4-Stream master
  output logic               o_axis_tvalid,
  input  logic               i_axis_tready,
  output logic [DATA_BW-1:0] o_axis_tdata
);

  assign o_ready = !o_axis_tvalid || i_axis_tready;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) o_axis_tvalid <= 1'b0;
    else if (o_ready) o_axis_tvalid <= i_valid;
  end

  always_ff @(posedge clk) begin
    if (o_ready && i_valid) o_axis_tdata <= i_pixel;
  end

endmodule
