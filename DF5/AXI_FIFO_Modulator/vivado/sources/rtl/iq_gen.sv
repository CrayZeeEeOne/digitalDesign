//==============================================================================
// iq_gen -- тестове джерело I/Q у залізі: GFSK-пакети в шумі, той самий формат,
// що й sim.iq (tools/iqgen.py), щоб демодулятор можна було ганяти без SD.
//
//   кадр:  0xAA x 8  ->  sync 0x91D3  ->  46 байт  ->  CRC-16/CCITT-FALSE
//   байти: "DF5 PKTnn " (nn = номер пакета 00..99), далі (17*nn + 7*i + 0x42)
//
// Кожні cfg_period відліків: cfg_gap відліків шуму, потім пакет (464 біти),
// потім знову шум до кінця періоду. Відліки виходять із темпом cfg_rate
// (NCO: carry акумулятора = один відлік; 2^32 * Fs / f_clk), або повільніше,
// якщо споживач тримає out_ready = 0.
//
// Модуляція: миттєва частота = cfg_fofs + cfg_dev * s(t), де s(t) -- NRZ +-1,
// згладжений гауссовим фільтром (BT 0.5): s = сума внесків попереднього,
// поточного й наступного біта з таблиці gen_gauss.mem (3 x 256, Q15).
// Шум: сума 4 рівномірних 12-бітних чисел (майже гаусів) * cfg_noise / 2^13,
// СКВ = 2365 * cfg_noise / 8192 (1470 -> 424 LSB, як у sim.iq при SNR 20 дБ).
//
// Один відлік рахується за 8 тактів (FSM), тож максимальний темп -- 12.5 МВід/с.
//==============================================================================
module iq_gen #(
  parameter GAUSS_FILE = "gen_gauss.mem",
  parameter SIN_FILE   = "nco_sin_1024.mem"
)(
  input  logic               clk,
  input  logic               rst,

  input  logic               cfg_enable,
  input  logic [31:0]        cfg_rate,       // 2^32 * Fs / f_clk
  input  logic [31:0]        cfg_fofs,       // зсув несучої, 2^32 = Fs (знаковий)
  input  logic [31:0]        cfg_dev,        // девіація, 2^32 = Fs
  input  logic [31:0]        cfg_bit_inc,    // 2^32 * bitrate / Fs
  input  logic [15:0]        cfg_amp,        // амплітуда, LSB
  input  logic [15:0]        cfg_noise,      // рівень шуму (див. вище)
  input  logic [31:0]        cfg_period,     // відліків на період
  input  logic [31:0]        cfg_gap,        // відліків шуму перед пакетом

  output logic               out_valid,
  input  logic               out_ready,
  output logic [31:0]        out_data,       // {Q, I}

  output logic [31:0]        st_pkts,        // пакетів відправлено
  output logic               st_burst        // зараз іде пакет
);

  localparam int NBITS = 58 * 8;              // 8 + 2 + 46 + 2 байти

  //---------------------------------------------------------- таблиці -----
  logic signed [15:0] gauss [0:767];
  logic signed [15:0] sinlut[0:1023];
  initial begin
    $readmemh(GAUSS_FILE, gauss);
    $readmemh(SIN_FILE, sinlut);
  end

  //------------------------------------------------------ темп відліків ---
  logic [31:0] rate_acc;
  logic        pending;                       // настав час наступного відліку
  logic        take;                          // FSM забирає його

  always_ff @(posedge clk) begin
    if (rst || !cfg_enable) begin
      rate_acc <= '0;
      pending  <= 1'b0;
    end
    else begin
      logic [32:0] s;
      s = {1'b0, rate_acc} + {1'b0, cfg_rate};
      rate_acc <= s[31:0];
      if (s[32]) pending <= 1'b1;
      else if (take) pending <= 1'b0;
    end
  end

  //------------------------------------------------------ байти кадру -----
  logic [3:0]  tens, ones;                    // номер пакета, десятковий
  logic [15:0] crc;

  function automatic logic [7:0] tag_char(input logic [3:0] idx, input logic [3:0] t, input logic [3:0] o);
    case (idx)
      4'd0: return 8'h44;  // D
      4'd1: return 8'h46;  // F
      4'd2: return 8'h35;  // 5
      4'd3: return 8'h20;
      4'd4: return 8'h50;  // P
      4'd5: return 8'h4B;  // K
      4'd6: return 8'h54;  // T
      4'd7: return 8'h30 + 8'(t);
      4'd8: return 8'h30 + 8'(o);
      default: return 8'h20;
    endcase
  endfunction

  // байт i кадру (CRC -- поточне значення, на момент його байтів уже готове)
  function automatic logic [7:0] frame_byte(input logic [5:0] i);
    logic [7:0] k, m;
    k = 8'(tens) * 8'd10 + 8'(ones);
    m = 8'(i) - 8'd10;
    if (i < 6'd8)       return 8'hAA;
    else if (i == 6'd8) return 8'h91;
    else if (i == 6'd9) return 8'hD3;
    else if (i < 6'd20) return tag_char(4'(m), tens, ones);
    else if (i < 6'd56) return k * 8'd17 + m * 8'd7 + 8'h42;
    else if (i == 6'd56) return crc[15:8];
    else                 return crc[7:0];
  endfunction

  //----------------------------------------------------------- стан -------
  typedef enum logic [3:0] {S_IDLE, S_G0, S_G1, S_G2, S_FREQ, S_PHASE, S_LUT, S_MUL, S_OUT} st_t;
  st_t st;

  logic [31:0] scnt;                          // відлік у періоді
  logic        burst;
  logic [31:0] bit_ph;
  logic [9:0]  bit_n;                         // поточний біт
  logic [9:0]  gen_n;                         // наступний біт, який буде згенеровано
  logic        b_prev, b_cur, b_next;         // NRZ: 1 -> +1, 0 -> -1
  logic        v_prev, v_cur, v_next;         // біт існує (у межах кадру)

  logic [31:0] phase;
  logic signed [17:0] shp;                    // згладжений NRZ, Q15
  logic signed [15:0] g_q;
  logic signed [15:0] s_q, c_q;
  logic signed [47:0] dev_prod;
  wire  signed [47:0] dev_shf = dev_prod >>> 15;     // окремо: знаковий зсув
  logic signed [31:0] sig_i, sig_q;
  logic signed [13:0] nz_i, nz_q;
  logic signed [31:0] nzp_i, nzp_q;
  logic [31:0] rnd_a, rnd_b, rnd_c, rnd_d;

  function automatic logic [31:0] xs32(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    return y ^ (y << 5);
  endfunction

  // наступний біт кадру за номером gen_n
  wire [7:0]  gb_byte = frame_byte(gen_n[9:3]);
  wire        gb_bit  = gb_byte[3'd7 - gen_n[2:0]];
  wire        gb_in   = gen_n < 10'(NBITS);
  wire        gb_pay  = gen_n >= 10'd80 && gen_n < 10'd448;   // біти payload -> CRC

  wire [7:0]  ph8 = bit_ph[31:24];

  function automatic logic signed [15:0] sat16(input logic signed [31:0] x);
    if (x > 32767)       return 16'sd32767;
    else if (x < -32768) return -16'sd32768;
    else                 return 16'(x);
  endfunction

  always_ff @(posedge clk) begin
    take <= 1'b0;
    if (rst || !cfg_enable) begin
      st        <= S_IDLE;
      out_valid <= 1'b0;
      scnt      <= '0;
      burst     <= 1'b0;
      bit_ph    <= '0;
      bit_n     <= '0;
      gen_n     <= '0;
      {b_prev, b_cur, b_next} <= '0;
      {v_prev, v_cur, v_next} <= '0;
      phase     <= '0;
      tens      <= '0;
      ones      <= '0;
      crc       <= 16'hFFFF;
      st_pkts   <= '0;
      rnd_a     <= 32'h1234_5678;
      rnd_b     <= 32'h9ABC_DEF1;
      rnd_c     <= 32'h0F1E_2D3C;
      rnd_d     <= 32'h4B5A_6978;
    end
    else begin
      if (out_valid && out_ready) out_valid <= 1'b0;

      case (st)
        //------------------------------------------------ розклад кадру
        S_IDLE: if (pending && !out_valid) begin
          take <= 1'b1;
          // початок пакета: біти -1 і 0 підготовлено, далі по одному наперед
          if (scnt == cfg_gap) begin
            burst  <= 1'b1;
            bit_ph <= '0;
            bit_n  <= '0;
            v_prev <= 1'b0;
            b_prev <= 1'b0;
            v_cur  <= 1'b1;
            b_cur  <= 1'b1;                     // перший біт 0xAA = 1
            v_next <= 1'b1;
            b_next <= 1'b0;
            gen_n  <= 10'd2;
            crc    <= 16'hFFFF;
          end
          st <= S_G0;
        end

        //------------------------------------- гауссове згладження NRZ
        // три читання таблиці: наступний, поточний, попередній біт
        S_G0: begin g_q <= gauss[{2'd0, ph8}]; shp <= '0; st <= S_G1; end
        S_G1: begin
          if (v_next) shp <= b_next ? 18'(g_q) : -18'(g_q);
          g_q <= gauss[10'd256 + 10'(ph8)];
          st  <= S_G2;
        end
        S_G2: begin
          if (v_cur) shp <= b_cur ? shp + 18'(g_q) : shp - 18'(g_q);
          g_q <= gauss[10'd512 + 10'(ph8)];
          st  <= S_FREQ;
        end
        S_FREQ: begin
          logic signed [17:0] s;
          s = shp;
          if (v_prev) s = b_prev ? s + 18'(g_q) : s - 18'(g_q);
          dev_prod <= $signed(cfg_dev) * s;
          st <= S_PHASE;
        end

        //------------------------------------------------- фаза + шум
        S_PHASE: begin
          phase <= phase + cfg_fofs + (burst ? 32'(dev_shf) : 32'd0);
          rnd_a <= xs32(rnd_a);
          rnd_b <= xs32(rnd_b);
          rnd_c <= xs32(rnd_c);
          rnd_d <= xs32(rnd_d);
          st <= S_LUT;
        end
        S_LUT: begin
          s_q  <= sinlut[phase[31:22]];
          c_q  <= sinlut[phase[31:22] + 10'd256];
          nz_i <= 14'($signed(rnd_a[11:0])) + 14'($signed(rnd_a[23:12])) +
                  14'($signed(rnd_b[11:0])) + 14'($signed(rnd_b[23:12]));
          nz_q <= 14'($signed(rnd_c[11:0])) + 14'($signed(rnd_c[23:12])) +
                  14'($signed(rnd_d[11:0])) + 14'($signed(rnd_d[23:12]));
          st <= S_MUL;
        end
        S_MUL: begin
          sig_i <= burst ? ($signed({1'b0, cfg_amp}) * c_q) >>> 15 : 32'sd0;
          sig_q <= burst ? ($signed({1'b0, cfg_amp}) * s_q) >>> 15 : 32'sd0;
          nzp_i <= nz_i * $signed({1'b0, cfg_noise});
          nzp_q <= nz_q * $signed({1'b0, cfg_noise});
          st <= S_OUT;
        end

        //------------------------------------- відлік + крок часу/бітів
        S_OUT: begin
          out_data  <= {sat16(sig_q + 32'(nzp_q >>> 13)), sat16(sig_i + 32'(nzp_i >>> 13))};
          out_valid <= 1'b1;

          // бітовий такт
          if (burst) begin
            logic [32:0] s;
            s = {1'b0, bit_ph} + {1'b0, cfg_bit_inc};
            bit_ph <= s[31:0];
            if (s[32]) begin
              bit_n  <= bit_n + 1'b1;
              {b_prev, v_prev} <= {b_cur, v_cur};
              {b_cur, v_cur}   <= {b_next, v_next};
              b_next <= gb_bit;
              v_next <= gb_in;
              gen_n  <= gen_n + 1'b1;
              if (gb_pay) crc <= {crc[14:0], 1'b0} ^ ((crc[15] ^ gb_bit) ? 16'h1021 : 16'h0000);
              if (bit_n + 1'b1 == 10'(NBITS)) begin
                burst   <= 1'b0;
                st_pkts <= st_pkts + 1'b1;
                if (ones == 4'd9) begin
                  ones <= '0;
                  tens <= (tens == 4'd9) ? 4'd0 : tens + 1'b1;
                end
                else ones <= ones + 1'b1;
              end
            end
          end

          scnt <= (scnt + 1'b1 >= cfg_period) ? 32'd0 : scnt + 1'b1;
          st   <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  assign st_burst = burst;

endmodule
