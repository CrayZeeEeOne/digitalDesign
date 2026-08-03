//==============================================================================
// filter_core -- чисто комбінаційне ядро нелінійних фільтрів 3x3
//
// Розкладка вікна в i_win (p0 -- молодші біти):
//        p0 p1 p2
//        p3 p4 p5
//        p6 p7 p8
//==============================================================================
module filter_core #(
  parameter int DATA_BW     = 8,
  parameter int WINDOW_SIZE = 9
)(
  input  logic [WINDOW_SIZE*DATA_BW-1:0] i_win,
  input  logic [1:0]                     i_config_select,
  output logic [DATA_BW-1:0]             o_pixel
);

  typedef enum logic [1:0] {
    F_MIN   = 2'b00,
    F_MAX   = 2'b01,
    F_MED   = 2'b10,
    F_SOBEL = 2'b11
  } filter_e;

  localparam logic [DATA_BW-1:0] PIX_MAX = '1;

  //--------------------------------------------------------------------------
  // Розпакування TDATA у масив пікселів
  //--------------------------------------------------------------------------
  logic [DATA_BW-1:0] p [0:WINDOW_SIZE-1];

  always_comb begin
    for (int i = 0; i < WINDOW_SIZE; i++)
      p[i] = i_win[i*DATA_BW +: DATA_BW];
  end

  //--------------------------------------------------------------------------
  // Min / Max -- дерево компараторів (4 рівні для 9 елементів)
  //--------------------------------------------------------------------------
  logic [DATA_BW-1:0] min_pix, max_pix;

  always_comb begin
    min_pix = p[0];
    max_pix = p[0];
    for (int i = 1; i < WINDOW_SIZE; i++) begin
      if (p[i] < min_pix) min_pix = p[i];
      if (p[i] > max_pix) max_pix = p[i];
    end
  end

  //--------------------------------------------------------------------------
  // Медіана -- сортувальна мережа на 19 compare-exchange
  // Мережа неповна: коректним гарантовано лише елемент s[4] (медіана).
  //--------------------------------------------------------------------------

  // compare-and-swap: повертає {менше, більше}
  function automatic logic [2*DATA_BW-1:0] cas (
    input logic [DATA_BW-1:0] a,
    input logic [DATA_BW-1:0] b
  );
    cas = (a <= b) ? {a, b} : {b, a};
  endfunction

  logic [DATA_BW-1:0] s [0:WINDOW_SIZE-1];
  logic [DATA_BW-1:0] med_pix;

  always_comb begin
    for (int i = 0; i < WINDOW_SIZE; i++) s[i] = p[i];

    // стадія 1
    {s[1], s[2]} = cas(s[1], s[2]);
    {s[4], s[5]} = cas(s[4], s[5]);
    {s[7], s[8]} = cas(s[7], s[8]);
    // стадія 2
    {s[0], s[1]} = cas(s[0], s[1]);
    {s[3], s[4]} = cas(s[3], s[4]);
    {s[6], s[7]} = cas(s[6], s[7]);
    // стадія 3
    {s[1], s[2]} = cas(s[1], s[2]);
    {s[4], s[5]} = cas(s[4], s[5]);
    {s[7], s[8]} = cas(s[7], s[8]);
    // стадія 4
    {s[0], s[3]} = cas(s[0], s[3]);
    {s[5], s[8]} = cas(s[5], s[8]);
    {s[4], s[7]} = cas(s[4], s[7]);
    // стадія 5
    {s[3], s[6]} = cas(s[3], s[6]);
    {s[1], s[4]} = cas(s[1], s[4]);
    {s[2], s[5]} = cas(s[2], s[5]);
    // стадія 6
    {s[4], s[7]} = cas(s[4], s[7]);
    {s[4], s[2]} = cas(s[4], s[2]);
    {s[6], s[4]} = cas(s[6], s[4]);
    {s[4], s[2]} = cas(s[4], s[2]);

    med_pix = s[4];
  end

  //--------------------------------------------------------------------------
  // Собель -- |Gx| + |Gy| без множників і без signed-арифметики
  //
  //   Gx = (p2 + 2*p5 + p8) - (p0 + 2*p3 + p6)
  //   Gy = (p6 + 2*p7 + p8) - (p0 + 2*p1 + p2)
  //
  // Розрядності: додатна частина <= 4*(2^DATA_BW - 1) -> DATA_BW+3 біт,
  //              |Gx| + |Gy|     <= 8*(2^DATA_BW - 1) -> DATA_BW+4 біт.
  //--------------------------------------------------------------------------
  localparam int PBW = DATA_BW + 3;   // часткові суми та модулі
  localparam int MBW = DATA_BW + 4;   // сума модулів

  logic [PBW-1:0] gx_pos, gx_neg, gy_pos, gy_neg;
  logic [PBW-1:0] abs_gx, abs_gy;
  logic [MBW-1:0] mag;
  logic [DATA_BW-1:0] sobel_pix;

  always_comb begin
    // {px, 1'b0} == px * 2, без ризику неявного обрізання
    gx_pos = PBW'(p[2]) + PBW'({p[5], 1'b0}) + PBW'(p[8]);
    gx_neg = PBW'(p[0]) + PBW'({p[3], 1'b0}) + PBW'(p[6]);
    gy_pos = PBW'(p[6]) + PBW'({p[7], 1'b0}) + PBW'(p[8]);
    gy_neg = PBW'(p[0]) + PBW'({p[1], 1'b0}) + PBW'(p[2]);

    abs_gx = (gx_pos >= gx_neg) ? (gx_pos - gx_neg) : (gx_neg - gx_pos);
    abs_gy = (gy_pos >= gy_neg) ? (gy_pos - gy_neg) : (gy_neg - gy_pos);

    mag = MBW'(abs_gx) + MBW'(abs_gy);

    // насичення до розрядності пікселя
    sobel_pix = (mag > MBW'(PIX_MAX)) ? PIX_MAX : mag[DATA_BW-1:0];
  end

  //--------------------------------------------------------------------------
  // Вибір результату
  //--------------------------------------------------------------------------
  always_comb begin
    unique case (filter_e'(i_config_select))
      F_MIN   : o_pixel = min_pix;
      F_MAX   : o_pixel = max_pix;
      F_MED   : o_pixel = med_pix;
      F_SOBEL : o_pixel = sobel_pix;
      default : o_pixel = '0;
    endcase
  end

endmodule
