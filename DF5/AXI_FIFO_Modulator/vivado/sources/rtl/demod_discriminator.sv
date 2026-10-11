//==============================================================================
// demod_discriminator -- FM-дискримінатор: кут між сусідніми відліками.
//
//   z[n] * conj(z[n-1]) = dot + j*cross
//   dot   = i*ip + q*qp
//   cross = q*ip - i*qp
//   dphi  = atan2(cross, dot)            -- миттєва частота, 2^15 = pi рад/відлік
//
// Перед CORDIC пара (dot, cross) нормалізується: зсувається вліво, доки
// більше з |dot|,|cross| не займе біт 32 у 34-бітному контейнері, потім
// беруться біти [33:16]. Так кут не залежить від амплітуди і точність
// однакова для слабких і сильних сигналів.
//
// Супутні дані (I, Q цього ж відліку) проходять конвеєром для вирівнювання.
// Латентність: 4 + (ITER + 1) = 21 такти.
//==============================================================================
module demod_discriminator (
  input  logic               clk,
  input  logic               rst,

  input  logic               in_valid,
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,

  output logic               out_valid,
  output logic signed [15:0] out_dphi,
  output logic signed [15:0] out_i,      // той самий відлік, вирівняний
  output logic signed [15:0] out_q
);

  //------------------------------------------------ стадія 1: добутки -----
  logic signed [15:0] ip, qp;             // попередній відлік
  logic               v1;
  logic signed [31:0] m_iip, m_qqp, m_qip, m_iqp;
  logic [31:0]        aux1;

  always_ff @(posedge clk) begin
    if (rst) begin
      ip <= '0;
      qp <= '0;
      v1 <= 1'b0;
    end
    else begin
      v1 <= in_valid;
      if (in_valid) begin
        ip    <= in_i;
        qp    <= in_q;
        m_iip <= in_i * ip;
        m_qqp <= in_q * qp;
        m_qip <= in_q * ip;
        m_iqp <= in_i * qp;
        aux1  <= {in_q, in_i};
      end
    end
  end

  //------------------------------------------------ стадія 2: суми --------
  logic               v2;
  logic signed [33:0] dot2, cross2;
  logic [31:0]        aux2;

  always_ff @(posedge clk) begin
    v2    <= v1 && !rst;
    dot2  <= 34'(m_iip) + 34'(m_qqp);
    cross2 <= 34'(m_qip) - 34'(m_iqp);
    aux2  <= aux1;
  end

  //------------------------------------- стадія 3: величина зсуву ---------
  function automatic logic [5:0] clz34(input logic [33:0] v);
    for (int k = 33; k >= 0; k--)
      if (v[k]) return 6'(33 - k);
    return 6'd34;
  endfunction

  logic               v3;
  logic signed [33:0] dot3, cross3;
  logic [5:0]         sh3;
  logic [31:0]        aux3;

  wire [33:0] abs_dot   = dot2[33]   ? -dot2   : dot2;
  wire [33:0] abs_cross = cross2[33] ? -cross2 : cross2;
  wire [33:0] mag       = (abs_dot > abs_cross) ? abs_dot : abs_cross;
  wire [5:0]  lz        = clz34(mag);

  always_ff @(posedge clk) begin
    v3     <= v2 && !rst;
    dot3   <= dot2;
    cross3 <= cross2;
    // MSB величини -> біт 32; при нульовому векторі зсув не має значення
    sh3    <= (lz == 6'd34) ? 6'd0 : (lz - 6'd1);
    aux3   <= aux2;
  end

  //------------------------------------- стадія 4: нормалізація -----------
  logic               v4;
  logic signed [17:0] x4, y4;
  logic [31:0]        aux4;

  wire signed [33:0] dot_sh   = dot3   <<< sh3;
  wire signed [33:0] cross_sh = cross3 <<< sh3;

  always_ff @(posedge clk) begin
    v4   <= v3 && !rst;
    x4   <= dot_sh[33:16];
    y4   <= cross_sh[33:16];
    aux4 <= aux3;
  end

  //------------------------------------------------------- CORDIC ----------
  logic [31:0] aux_out;

  demod_cordic_atan2 #(.W(18), .ITER(16), .AUX_W(32)) u_cordic (
    .clk       (clk),
    .rst       (rst),
    .in_valid  (v4),
    .in_x      (x4),
    .in_y      (y4),
    .in_aux    (aux4),
    .out_valid (out_valid),
    .out_angle (out_dphi),
    .out_aux   (aux_out)
  );

  assign out_i = aux_out[15:0];
  assign out_q = aux_out[31:16];

endmodule
