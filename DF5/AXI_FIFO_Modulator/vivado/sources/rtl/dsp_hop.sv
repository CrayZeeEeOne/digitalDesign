//==============================================================================
// dsp_hop -- пошук пакета по 15 hop-каналах і перестройка демодулятора.
//
// Пакети Alarm-Beacon щоразу йдуть на іншому з 15 каналів (865.3..869.5 МГц),
// а демодулятор один. FFT (dsp_spectrum) рахує кожен блок із 256 відліків ДО
// лінії затримки, демодулятор отримує ті самі відліки через DL_LEN = 4096
// відліків. Отже, коли FFT бачить початок пакета на каналі c, до демодулятора
// він дійде лише через ~3000+ відліків -- за цей час NCO демодулятора
// перестроюється на c (nco_inc = таблиця[c]).
//
// На кожен оброблений блок (ch_done):
//   1. для кожного каналу: ch_pow[c] > max(noise[c] << cfg_thr_sh, cfg_thr_min)
//      -> "є сигнал" (мінімум потрібен, бо шум запису після FFT -- одиниці LSB);
//      noise[c] -- IIR (зсув cfg_noise_sh) суми рівнів каналу, оновлюється лише
//      без сигналу; перші 16 блоків після скиду -- розгін (перший блок задає
//      стартове значення, далі швидкий IIR >> 2), виявлення ще немає;
//   2. найсильніший канал із сигналом -- кандидат; cfg_confirm блоків поспіль
//      на тому самому каналі -> виявлено (det);
//   3. стан:
//        IDLE  виявлено -> NCO на канал, trig (запуск захоплення), WAIT
//        WAIT  демодулятор побачив burst -> BUSY; cfg_hold відліків без нього
//              (хибне виявлення) -> IDLE
//        BUSY  burst закінчився (або 2^17 відліків) -> IDLE
//      Поки WAIT/BUSY, нові виявлення ігноруються: демодулятор один.
//
// Канал перевіряється за ~15 тактів після ch_done (по одному за такт).
//==============================================================================
module dsp_hop (
  input  logic               clk,
  input  logic               rst,

  input  logic               cfg_en,
  input  logic [3:0]         cfg_thr_sh,     // поріг: noise << thr_sh (5 = x32, ~30 дБ)
  input  logic [3:0]         cfg_noise_sh,   // IIR шуму каналу
  input  logic [3:0]         cfg_confirm,    // блоків поспіль для виявлення
  input  logic [15:0]        cfg_thr_min,    // поріг не нижче за це
  input  logic [15:0]        cfg_hold,       // відліків чекати burst після перестройки
  input  logic [31:0]        cfg_nco [0:14], // NCO_INC демодулятора для кожного каналу

  input  logic [23:0]        ch_pow [0:14],
  input  logic               ch_done,
  input  logic               in_fire,        // вхідний відлік (для таймерів)
  input  logic               demod_burst,    // демодулятор у пакеті (затриманий потік)

  output logic               nco_en,
  output logic [31:0]        nco_inc,
  output logic [3:0]         cur_ch,
  output logic               trig,           // строб: пакет виявлено, NCO перестроєно
  output logic [1:0]         st_state,
  output logic [15:0]        st_dets,        // виявлень
  output logic [15:0]        st_lost         // виявлень, по яких демодулятор нічого не побачив
);

  typedef enum logic [1:0] {H_IDLE = 2'd0, H_WAIT = 2'd1, H_BUSY = 2'd2} hst_t;
  hst_t hs;

  logic [23:0] noise [0:14];
  logic        noise_ok;                       // розгін шуму закінчено
  logic [3:0]  warm;                           // блоків розгону
  logic        scan;                           // перевірка каналів іде
  logic        decide;                         // перевірку закінчено: рішення
  logic [3:0]  sc;                             // канал, що перевіряється
  logic        best_v;
  logic [3:0]  best;
  logic [23:0] best_pow;
  logic [3:0]  cand;
  logic [3:0]  cand_n;
  logic [17:0] timer;

  wire [23:0] pw  = ch_pow[sc];
  wire [23:0] nz  = noise[sc];
  wire [31:0] thr_n = 32'(nz) << cfg_thr_sh;
  wire [31:0] thr   = (thr_n > 32'(cfg_thr_min)) ? thr_n : 32'(cfg_thr_min);
  wire        hit = noise_ok && (32'(pw) > thr);
  wire signed [24:0] nd = $signed({1'b0, pw}) - $signed({1'b0, nz});

  assign nco_en  = cfg_en;
  assign st_state = hs;

  always_ff @(posedge clk) begin
    trig   <= 1'b0;
    decide <= 1'b0;
    if (rst) begin
      hs       <= H_IDLE;
      noise_ok <= 1'b0;
      warm     <= '0;
      scan     <= 1'b0;
      sc       <= '0;
      best_v   <= 1'b0;
      cand     <= 4'd15;
      cand_n   <= '0;
      cur_ch   <= '0;
      nco_inc  <= '0;
      timer    <= '0;
      st_dets  <= '0;
      st_lost  <= '0;
    end
    else begin
      //---------------------------------------------- перевірка каналів
      if (ch_done && !scan) begin
        scan   <= 1'b1;
        sc     <= '0;
        best_v <= 1'b0;
      end
      else if (scan) begin
        if (!noise_ok && warm == 0) noise[sc] <= pw;
        else if (!noise_ok)         noise[sc] <= nz + 24'(nd >>> 2);
        else if (!hit)              noise[sc] <= nz + 24'(nd >>> cfg_noise_sh);
        if (hit && (!best_v || pw > best_pow)) begin
          best_v   <= 1'b1;
          best     <= sc;
          best_pow <= pw;
        end
        if (sc == 4'd14) begin
          scan   <= 1'b0;
          decide <= noise_ok;
          if (!noise_ok) begin
            warm <= warm + 1'b1;
            if (warm == 4'd15) noise_ok <= 1'b1;
          end
        end
        else sc <= sc + 1'b1;
      end

      //------------------------------------------- кандидат і рішення
      // такт після останнього каналу: best готовий
      if (decide) begin
        if (!best_v) begin
          cand   <= 4'd15;
          cand_n <= '0;
        end
        else if (best == cand) begin
          if (cand_n != 4'd15) cand_n <= cand_n + 1'b1;
          if (cfg_en && hs == H_IDLE && cand_n + 1'b1 >= cfg_confirm) begin
            hs      <= H_WAIT;
            timer   <= 18'(cfg_hold);
            cur_ch  <= best;
            nco_inc <= cfg_nco[best];
            trig    <= 1'b1;
            st_dets <= st_dets + 1'b1;
            cand_n  <= '0;
            cand    <= 4'd15;
          end
        end
        else begin
          cand   <= best;
          cand_n <= 4'd1;
          if (cfg_en && hs == H_IDLE && cfg_confirm <= 4'd1) begin
            hs      <= H_WAIT;
            timer   <= 18'(cfg_hold);
            cur_ch  <= best;
            nco_inc <= cfg_nco[best];
            trig    <= 1'b1;
            st_dets <= st_dets + 1'b1;
            cand_n  <= '0;
            cand    <= 4'd15;
          end
        end
      end

      //------------------------------------------------------ стан
      case (hs)
        H_WAIT: begin
          if (demod_burst) begin
            hs    <= H_BUSY;
            timer <= 18'h3FFFF;
          end
          else if (in_fire) begin
            if (timer == 0) begin
              hs      <= H_IDLE;
              st_lost <= st_lost + 1'b1;
            end
            else timer <= timer - 1'b1;
          end
        end
        H_BUSY: begin
          if (!demod_burst) hs <= H_IDLE;
          else if (in_fire) begin
            if (timer == 0) hs <= H_IDLE;
            else timer <= timer - 1'b1;
          end
        end
        default: ;
      endcase
      if (!cfg_en) hs <= H_IDLE;
    end
  end

endmodule
