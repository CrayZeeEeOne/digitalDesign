//==============================================================================
// demod_nco_mixer -- зсув спектра: множення вхідного I/Q на e^{+j*theta},
// theta накопичується з кроком nco_inc (2^32 = 2*pi, тобто
// f_nco = nco_inc / 2^32 * Fs). Додатний nco_inc зсуває спектр угору.
//
// Таблиця синуса 1024 x Q15 читається з .mem ($readmemh), cos = sin[k+256].
// Вихід = (x * lut) >> 16, тобто підсилення 1/2 -- так сума двох добутків
// гарантовано влазить у 16 біт без насичення.
//
// Латентність: 3 такти, in_valid -> out_valid.
//==============================================================================
module demod_nco_mixer #(
  parameter LUT_FILE = "nco_sin_1024.mem"
)(
  input  logic               clk,
  input  logic               rst,

  input  logic [31:0]        nco_inc,

  input  logic               in_valid,
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,

  output logic               out_valid,
  output logic signed [15:0] out_i,
  output logic signed [15:0] out_q
);

  logic signed [15:0] lut [0:1023];
  initial $readmemh(LUT_FILE, lut);

  logic [31:0] phase;

  always_ff @(posedge clk) begin
    if (rst)           phase <= '0;
    else if (in_valid) phase <= phase + nco_inc;
  end

  wire [9:0] idx_s = phase[31:22];
  wire [9:0] idx_c = phase[31:22] + 10'd256;

  //---------------------------------------------------------- стадія 1 ---
  logic               v1;
  logic signed [15:0] i1, q1, s1, c1;

  always_ff @(posedge clk) begin
    v1 <= in_valid && !rst;
    i1 <= in_i;
    q1 <= in_q;
    s1 <= lut[idx_s];
    c1 <= lut[idx_c];
  end

  //---------------------------------------------------------- стадія 2 ---
  logic               v2;
  logic signed [31:0] p_ic, p_qs, p_is, p_qc;

  always_ff @(posedge clk) begin
    v2   <= v1;
    p_ic <= i1 * c1;
    p_qs <= q1 * s1;
    p_is <= i1 * s1;
    p_qc <= q1 * c1;
  end

  //---------------------------------------------------------- стадія 3 ---
  logic signed [32:0] sum_i, sum_q;
  assign sum_i = 33'(p_ic) - 33'(p_qs);
  assign sum_q = 33'(p_is) + 33'(p_qc);

  always_ff @(posedge clk) begin
    out_valid <= v2;
    out_i     <= sum_i[31:16];
    out_q     <= sum_q[31:16];
  end

endmodule
