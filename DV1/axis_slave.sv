//==============================================================================
// axis_slave -- вхідний канал AXI4-Stream (спрощений).
//
// Приймає вікно 3x3 та поточний i_config_select, реєструє їх і віддає
// далі по внутрішньому valid/ready. Це перший ступінь конвеєра.
//==============================================================================
module axis_slave #(
  parameter int DATA_BW     = 8,
  parameter int WINDOW_SIZE = 9,
  localparam int TDATA_BW   = WINDOW_SIZE * DATA_BW
)(
  input  logic                clk,
  input  logic                rstn,

  // AXI4-Stream slave
  input  logic                i_axis_tvalid,
  output logic                o_axis_tready,
  input  logic [TDATA_BW-1:0] i_axis_tdata,

  // конфігурація (семплиться разом з вікном)
  input  logic [1:0]          i_config_select,

  // внутрішній канал до filter_core
  output logic [TDATA_BW-1:0] o_win,
  output logic [1:0]          o_cfg,
  output logic                o_valid,
  input  logic                i_ready
);

  // Стадія готова прийняти, якщо вона порожня або її вміст забирають цього такту.
  // TREADY залежить від наступного TREADY, але НЕ від TVALID -- це вимога AXI.
  assign o_axis_tready = !o_valid || i_ready;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) o_valid <= 1'b0;
    else if (o_axis_tready) o_valid <= i_axis_tvalid;
  end

  // Датапас без скидання -- економія логіки, значення дійсне лише при o_valid.
  always_ff @(posedge clk) begin
    if (o_axis_tready && i_axis_tvalid) begin
      o_win <= i_axis_tdata;
      o_cfg <= i_config_select;
    end
  end

endmodule
