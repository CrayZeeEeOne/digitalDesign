//==============================================================================
// dsp_spectrum -- спектр і waterfall захоплення, у залізі замість
// vitis/src/dsp/spectrum.c + fft.c + capture_block() (арифметика та сама, біт
// у біт: tools/check_dsp_capture.py звіряє з Python-копією C-коду).
//
// Вхідний потік ріжеться на блоки по 256 відліків (рахунок від скиду). Блок, у
// якому хоч один відлік записувався захопленням (in_rec), обробляється:
//
//   вікно Ханна (fft_hann256.mem) -> FFT-256 radix-2, кожна стадія /2
//   (twiddle з fft_sin257.mem, як sin_q15() у C) -> |re| + |im| 128 центральних
//   бінів -> накопичення; кожні 2^cfg_wf_shift блоків -> рядок waterfall
//   spec_log(acc >> cfg_wf_shift) (~16*log2). Max hold по рядках рахує софт
//   (40 x 128 порівнянь), у залізі він не потрібен.
//
// Пам'ять: два банки 256 x {im, re} (у один пишеться вхід, другий рахує FFT),
// waterfall WF_ROWS x 128 байт, накопичувачі 128 x 32 (синхронна RAM).
// FFT: 8 стадій x 128 метеликів по 2 такти + дренаж -> ~2.1 тис. тактів на
// блок. Якщо наступний блок прийшов раніше, ніж FFT закінчив, in_ready = 0.
//==============================================================================
module dsp_spectrum #(
  parameter int WF_ROWS   = 40,
  parameter     HANN_FILE = "fft_hann256.mem",
  parameter     SIN_FILE  = "fft_sin257.mem"
)(
  input  logic               clk,
  input  logic               rst,

  input  logic               arm,            // нове захоплення: обнулити накопичення
  input  logic [4:0]         cfg_wf_shift,   // блоків на рядок = 2^cfg_wf_shift

  input  logic               in_valid,       // прийнятий відлік потоку
  input  logic               in_rec,         // цей відлік записується захопленням
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,
  output logic               in_ready,

  output logic [7:0]         st_rows,        // записано рядків
  output logic               st_busy,

  // читання з AXI (синхронне: дані наступного такту)
  input  logic               rd_en,
  input  logic [10:0]        rd_wf_addr,     // слово: рядок*32 + бін/4
  output logic [31:0]        rd_wf_data      // біни 4w..4w+3, молодший -- у [7:0]
);

  //---------------------------------------------------------- таблиці -----
  logic signed [15:0] hann [0:255];
  logic signed [15:0] sinq [0:256];
  initial begin
    $readmemh(HANN_FILE, hann);
    $readmemh(SIN_FILE, sinq);
  end

  function automatic logic signed [15:0] sin_q15(input logic [15:0] ph);
    logic [9:0] idx;
    logic [7:0] o;
    idx = ph[15:6];
    o   = idx[7:0];
    case (idx[9:8])
      2'd0: return  sinq[{1'b0, o}];
      2'd1: return  sinq[9'd256 - {1'b0, o}];
      2'd2: return -sinq[{1'b0, o}];
      default: return -sinq[9'd256 - {1'b0, o}];
    endcase
  endfunction

  function automatic logic [7:0] bitrev8(input logic [7:0] x);
    for (int k = 0; k < 8; k++) bitrev8[k] = x[7 - k];
  endfunction

  function automatic logic [7:0] spec_log(input logic [31:0] x);
    logic [4:0] n;
    logic [3:0] fr;
    logic [9:0] v;
    if (x == 0) return 8'd0;
    n = 0;
    for (int k = 0; k < 32; k++) if (x[k]) n = 5'(k);       // старший одиничний біт
    if (n >= 4) fr = 4'(x >> (n - 4));
    else        fr = 4'(x << (4 - n));
    v = {n, 4'd0} + 10'(fr);
    return (v > 10'd255) ? 8'd255 : v[7:0];
  endfunction

  //--------------------------------------------------- банки {im, re} -----
  logic [31:0] bank0 [0:255];
  logic [31:0] bank1 [0:255];

  logic        wb;                             // банк, у який пише вхід
  logic        fb;                             // банк, на якому працює FFT

  // порт A: вхід (у банк wb) або FFT-a/читання результату (у банк fb)
  // порт B: FFT-b (у банк fb)
  logic        a_we_in;  logic [7:0] a_addr_in;  logic [31:0] a_din_in;
  logic        a_we_f;   logic [7:0] a_addr_f;   logic [31:0] a_din_f;
  logic        b_we_f;   logic [7:0] b_addr_f;   logic [31:0] b_din_f;
  logic [7:0]  a_waddr, b_waddr;               // адреси запису метелика (регістр)
  logic [7:0]  a_raddr, b_raddr;               // адреси читання (комбінаційно)
  logic [31:0] a_dout0, a_dout1, b_dout0, b_dout1;

  wire         a0_we   = (wb == 1'b0) ? a_we_in   : a_we_f;
  wire [7:0]   a0_addr = (wb == 1'b0) ? a_addr_in : a_addr_f;
  wire [31:0]  a0_din  = (wb == 1'b0) ? a_din_in  : a_din_f;
  wire         a1_we   = (wb == 1'b1) ? a_we_in   : a_we_f;
  wire [7:0]   a1_addr = (wb == 1'b1) ? a_addr_in : a_addr_f;
  wire [31:0]  a1_din  = (wb == 1'b1) ? a_din_in  : a_din_f;
  wire         b0_we   = (fb == 1'b0) && b_we_f;
  wire         b1_we   = (fb == 1'b1) && b_we_f;

  always_ff @(posedge clk) begin
    if (a0_we) bank0[a0_addr] <= a0_din;
    a_dout0 <= bank0[a0_addr];
  end
  always_ff @(posedge clk) begin
    if (b0_we) bank0[b_addr_f] <= b_din_f;
    b_dout0 <= bank0[b_addr_f];
  end
  always_ff @(posedge clk) begin
    if (a1_we) bank1[a1_addr] <= a1_din;
    a_dout1 <= bank1[a1_addr];
  end
  always_ff @(posedge clk) begin
    if (b1_we) bank1[b_addr_f] <= b_din_f;
    b_dout1 <= bank1[b_addr_f];
  end

  wire [31:0] fa_dout = fb ? a_dout1 : a_dout0;
  wire [31:0] fb_dout = fb ? b_dout1 : b_dout0;

  //----------------------------------------------------- вхід (вікно) -----
  logic [7:0]         n_in;                    // номер відліку в блоці
  logic               s1_v;
  logic [7:0]         s1_n;
  logic signed [15:0] s1_i, s1_q;
  logic               blk_rec;                 // блок треба обробити
  logic               pend;                    // блок повний, чекає вільного FFT
  logic               fft_start;
  logic               fft_busy;

  assign in_ready = !pend;
  wire   in_fire  = in_valid && in_ready;

  wire signed [31:0] w_i = s1_i * hann[s1_n];
  wire signed [31:0] w_q = s1_q * hann[s1_n];

  assign a_we_in   = s1_v;
  assign a_addr_in = bitrev8(s1_n);
  assign a_din_in  = {w_q[30:15], w_i[30:15]};

  always_ff @(posedge clk) begin
    if (rst) begin
      n_in    <= '0;
      s1_v    <= 1'b0;
      blk_rec <= 1'b0;
      pend    <= 1'b0;
      wb      <= 1'b0;
      fb      <= 1'b1;
      fft_start <= 1'b0;
    end
    else begin
      fft_start <= 1'b0;
      s1_v <= in_fire;
      if (in_fire) begin
        s1_n <= n_in;
        s1_i <= in_i;
        s1_q <= in_q;
        n_in <= n_in + 1'b1;
        if (in_rec) blk_rec <= 1'b1;
        if (n_in == 8'd255) begin
          if (blk_rec || in_rec) pend <= 1'b1;
          else                   blk_rec <= 1'b0;
        end
      end
      // останній відлік блоку записано (s1 вже порожній) -> віддати банк FFT
      if (pend && !s1_v && !fft_busy && !fft_start) begin
        pend      <= 1'b0;
        blk_rec   <= 1'b0;
        fb        <= wb;
        wb        <= ~wb;
        fft_start <= 1'b1;
      end
    end
  end

  //----------------------------------------------------------- FFT ---------
  typedef enum logic [2:0] {F_IDLE, F_RUN, F_DRAIN, F_OUT, F_OUT_DRAIN} fst_t;
  fst_t fst;
  logic [6:0] o_n;                             // бін, що читається (F_OUT)

  logic [2:0] stage;                           // 0..7: len = 2 << stage
  logic [6:0] bfly;                            // 0..127
  logic       phase_rd;                        // такт читання (парний)
  logic [2:0] drain;

  // адреси метелика
  logic [7:0]  ba, bb;
  logic [15:0] tw_ph;
  always_comb begin
    logic [7:0] grp, k, half;
    half  = 8'd1 << stage;
    k     = 8'(bfly) & (half - 8'd1);
    grp   = 8'(bfly) >> stage;
    ba    = (grp << (stage + 1)) | k;
    bb    = ba + half;
    tw_ph = 16'(k) << (15 - stage);
  end

  // Порти банку fb: запис метелика має пріоритет (непарні такти), інакше
  // читання -- адреса комбінаційна, дані з BRAM у наступному такті.
  assign a_addr_f = a_we_f ? a_waddr : a_raddr;
  assign b_addr_f = b_we_f ? b_waddr : b_raddr;

  // конвеєр метелика: R (читання) -> M (добутки) -> S (суми) -> W (запис)
  logic               m_v, s_v;
  logic [7:0]         m_a, m_b, s_a, s_b;
  logic signed [15:0] m_wr, m_wi;
  logic signed [31:0] p_rr, p_ii, p_ri, p_ir;
  logic signed [15:0] s_ra, s_ia;
  logic signed [15:0] m_ra, m_ia;
  logic [31:0]        s_new_a, s_new_b;

  wire [7:0] o_addr = 8'(o_n) - 8'd64;          // бін k = (n - 64) & 255
  assign a_raddr = (fst == F_OUT) ? o_addr : ba;
  assign b_raddr = bb;

  // такт M: дані з BRAM
  wire signed [15:0] d_ra = fa_dout[15:0];
  wire signed [15:0] d_ia = fa_dout[31:16];
  wire signed [15:0] d_rb = fb_dout[15:0];
  wire signed [15:0] d_ib = fb_dout[31:16];

  // такт S -> W
  wire signed [32:0] tr33 = 33'(p_rr) - 33'(p_ii);
  wire signed [32:0] ti33 = 33'(p_ri) + 33'(p_ir);
  wire signed [31:0] tr   = 32'(tr33 >>> 15);
  wire signed [31:0] ti   = 32'(ti33 >>> 15);
  wire signed [31:0] ra_m = 32'(s_ra) - tr;
  wire signed [31:0] ia_m = 32'(s_ia) - ti;
  wire signed [31:0] ra_p = 32'(s_ra) + tr;
  wire signed [31:0] ia_p = 32'(s_ia) + ti;

  // читання результату
  logic        o1_v, o2_v;
  logic [6:0]  o1_n, o2_n;
  logic [16:0] o_mag;
  logic [31:0] o_sum;
  logic        row_last;                       // поточний блок завершує рядок
  logic [15:0] blocks_lo;
  logic [31:0] blocks;
  logic [7:0]  rows;

  logic        clr_act;
  logic [6:0]  clr_n;
  logic [31:0] acc [0:127];
  // waterfall: 4 байтові лани (бін % 4), щоб читати слово за раз
  logic [7:0]  wf0 [0:WF_ROWS*32-1];
  logic [7:0]  wf1 [0:WF_ROWS*32-1];
  logic [7:0]  wf2 [0:WF_ROWS*32-1];
  logic [7:0]  wf3 [0:WF_ROWS*32-1];
  logic        wf_we;
  logic [10:0] wf_waddr;
  logic [1:0]  wf_lane;
  logic [7:0]  wf_wdata;

  // накопичувачі: один порт запису (рядок або обнулення), синхронне читання
  // за адресою біна в такті F_OUT -> дані в такті o1, разом із даними банку
  logic        acc_we;
  logic [6:0]  acc_waddr;
  logic [31:0] acc_wdata, acc_rd;
  always_ff @(posedge clk) begin
    if (acc_we) acc[acc_waddr] <= acc_wdata;
    acc_rd <= acc[o_n];
  end
  wire [31:0] o_shift  = o_sum >> cfg_wf_shift;
  wire [7:0]  o_log    = spec_log(o_shift);

  always_ff @(posedge clk) begin
    a_we_f <= 1'b0;
    b_we_f <= 1'b0;
    wf_we  <= 1'b0;
    acc_we <= 1'b0;
    if (rst) begin
      fst      <= F_IDLE;
      fft_busy <= 1'b0;
      m_v <= 1'b0; s_v <= 1'b0;
      o1_v <= 1'b0; o2_v <= 1'b0;
      blocks <= '0;
      blocks_lo <= '0;
      rows   <= '0;
      clr_act <= 1'b1;
      clr_n   <= '0;
    end
    else begin
      //------------------------------------------------------- метелики
      // R: адреси на порти A/B (банк fb)
      m_v <= 1'b0;
      if (fst == F_RUN && phase_rd) begin
        m_v  <= 1'b1;
        m_a  <= ba;
        m_b  <= bb;
        m_wr <= sin_q15(tw_ph + 16'd16384);
        m_wi <= -sin_q15(tw_ph);
      end
      // M: дані прийшли (BRAM має один такт латентності)
      s_v <= 1'b0;
      if (m_v) begin
        s_v  <= 1'b1;
        s_a  <= m_a;
        s_b  <= m_b;
        s_ra <= d_ra;
        s_ia <= d_ia;
        p_rr <= d_rb * m_wr;
        p_ii <= d_ib * m_wi;
        p_ri <= d_rb * m_wi;
        p_ir <= d_ib * m_wr;
      end
      // S: суми -> запис (непарний такт: порти вільні від читань)
      if (s_v) begin
        a_we_f   <= 1'b1;
        b_we_f   <= 1'b1;
        a_waddr  <= s_a;
        b_waddr  <= s_b;
        a_din_f  <= {16'(ia_p >>> 1), 16'(ra_p >>> 1)};
        b_din_f  <= {16'(ia_m >>> 1), 16'(ra_m >>> 1)};
      end

      //-------------------------------------------------- керування FFT
      case (fst)
        F_IDLE: if (fft_start) begin
          fft_busy <= 1'b1;
          stage    <= '0;
          bfly     <= '0;
          phase_rd <= 1'b1;
          fst      <= F_RUN;
        end
        F_RUN: begin
          phase_rd <= ~phase_rd;
          if (phase_rd) begin
            bfly <= bfly + 1'b1;
            if (bfly == 7'd127) begin
              fst   <= F_DRAIN;
              drain <= 3'd5;
            end
          end
        end
        F_DRAIN: begin
          // останній запис стадії має завершитися до першого читання наступної
          if (drain != 0) drain <= drain - 1'b1;
          else if (stage == 3'd7) begin
            fst      <= F_OUT;
            o_n      <= '0;
            row_last <= (blocks_lo == (16'd1 << cfg_wf_shift) - 16'd1);
          end
          else begin
            stage    <= stage + 1'b1;
            bfly     <= '0;
            phase_rd <= 1'b1;
            fst      <= F_RUN;
          end
        end
        //------------------------------- 128 центральних бінів -> рядок
        F_OUT: begin
          o_n      <= o_n + 1'b1;
          if (o_n == 7'd127) begin
            fst   <= F_OUT_DRAIN;
            drain <= 3'd3;
          end
        end
        F_OUT_DRAIN: begin
          if (drain != 0) drain <= drain - 1'b1;
          else begin
            fst      <= F_IDLE;
            fft_busy <= 1'b0;
            if (row_last) begin
              blocks_lo <= '0;
              if (rows < 8'(WF_ROWS)) rows <= rows + 1'b1;
            end
            else blocks_lo <= blocks_lo + 1'b1;
            blocks <= blocks + 1'b1;
          end
        end
        default: fst <= F_IDLE;
      endcase

      // конвеєр читання: такт 1 -- дані BRAM -> |re|+|im|, + накопичене
      o1_v <= (fst == F_OUT);
      o1_n <= o_n;
      if (o1_v) begin
        logic signed [15:0] re, im;
        logic [16:0] m;
        re = fa_dout[15:0];
        im = fa_dout[31:16];
        m  = 17'(re < 0 ? -32'(re) : 32'(re)) + 17'(im < 0 ? -32'(im) : 32'(im));
        o_sum <= acc_rd + ((m > 17'd65535) ? 32'd65535 : 32'(m));
      end
      o2_v <= o1_v;
      o2_n <= o1_n;
      // такт 2: запис накопичувача / рядка / max hold
      if (o2_v) begin
        acc_we    <= 1'b1;
        acc_waddr <= o2_n;
        acc_wdata <= row_last ? 32'd0 : o_sum;
        if (row_last) begin
          if (rows < 8'(WF_ROWS)) begin
            wf_we    <= 1'b1;
            wf_waddr <= 11'(rows) * 11'd32 + 11'(o2_n[6:2]);
            wf_lane  <= o2_n[1:0];
            wf_wdata <= o_log;
          end
        end
      end

      // обнулення накопичувачів після arm: 128 тактів
      if (clr_act) begin
        acc_we     <= 1'b1;
        acc_waddr  <= clr_n;
        acc_wdata  <= '0;
        clr_n      <= clr_n + 1'b1;
        if (clr_n == 7'd127) clr_act <= 1'b0;
      end

      if (arm) begin
        blocks    <= '0;
        blocks_lo <= '0;
        rows      <= '0;
        clr_act   <= 1'b1;
        clr_n     <= '0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (wf_we) begin
      case (wf_lane)
        2'd0: wf0[wf_waddr] <= wf_wdata;
        2'd1: wf1[wf_waddr] <= wf_wdata;
        2'd2: wf2[wf_waddr] <= wf_wdata;
        default: wf3[wf_waddr] <= wf_wdata;
      endcase
    end
  end

  // читання з AXI
  always_ff @(posedge clk) begin
    if (rd_en) begin
      rd_wf_data <= {wf3[rd_wf_addr], wf2[rd_wf_addr], wf1[rd_wf_addr], wf0[rd_wf_addr]};
    end
  end

  assign st_rows = rows;
  assign st_busy = fft_busy || pend || clr_act;

endmodule
