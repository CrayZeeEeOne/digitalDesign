//==============================================================================
// demod_bit_decoder -- усе, що відбувається з миттєвою частотою після
// детектора пакета:
//
//   1. слайсер з AFC: поріг favg = повільне середнє dphi (швидко на старті
//      пакета, повільно далі; заморожується після sync);
//   2. оцінка девіації: середнє |dphi - favg| (теж заморожується);
//   3. відновлення бітового такту: NCO з кроком bit_inc, на кожному переході
//      рішення фаза підтягується до середини інтервалу (err/4);
//   4. вікно вимірювання: поки останні 8 біт чергуються (преамбула),
//      між першим і останнім переходом рахуємо відліки, переходи та суму dphi
//      -> софт отримує точні бітрейт і несучу без ripple IIR;
//   5. детектор преамбули (0xAAAA/0x5555) і sync-слова (пряме або
//      інвертоване -- тоді далі всі біти інвертуються);
//   6. збирання байтів MSB-first, CRC-16 біт за бітом по всьому пакету,
//      запис байтів у пам'ять пакета, результат після pkt_len байтів.
//
// Арифметика збігається з tools/demod_model.py один в один.
//==============================================================================
module demod_bit_decoder (
  input  logic               clk,
  input  logic               rst,

  // конфігурація
  input  logic [15:0]        cfg_freq_init,
  input  logic [3:0]         cfg_sh_fast,
  input  logic [3:0]         cfg_sh_slow,
  input  logic [15:0]        cfg_fast_len,
  input  logic [3:0]         cfg_dev_shift,
  input  logic [15:0]        cfg_bit_inc,
  input  logic [15:0]        cfg_sync_word,
  input  logic [7:0]         cfg_pkt_len,
  input  logic [15:0]        cfg_crc_poly,
  input  logic [15:0]        cfg_crc_init,
  input  logic [15:0]        cfg_crc_residue,

  // вхід від demod_power (вирівняний)
  input  logic               in_valid,
  input  logic signed [15:0] in_dphi,
  input  logic               in_burst,
  input  logic               in_burst_start,
  input  logic               in_burst_end,
  input  logic [31:0]        in_burst_len,

  // пам'ять пакета
  output logic               pkt_we,
  output logic [7:0]         pkt_waddr,
  output logic [7:0]         pkt_wdata,

  // поточний стан
  output logic               st_synced,
  output logic               st_pkt_active,
  output logic               st_preamble,
  output logic               st_inverted,
  output logic signed [15:0] st_favg,
  output logic [15:0]        st_dev,

  // рішення слайсера на кожному бітовому такті в пакеті (для захоплення)
  output logic               tap_bit_v,
  output logic               tap_bit,

  // результат (однотактовий строб, поля дійсні в тому ж такті)
  output logic               res_strobe,
  output logic [1:0]         res_kind,       // 0 пакет, 1 пакет без sync, 2 обірваний
  output logic               res_crc_ok,
  output logic [15:0]        res_bits,
  output logic [7:0]         res_bytes,
  output logic [7:0]         res_pkts_in_burst,
  output logic [15:0]        res_win_trans,
  output logic [15:0]        res_win_cnt,
  output logic signed [31:0] res_win_fsum
);

  //------------------------------------------------------------- стан -----
  logic signed [23:0] favg;              // Q15 кут з 8 дробовими бітами
  logic        [23:0] dev;
  logic               synced, inverted, preamble, pkt_active;
  logic               bit_prev;
  logic        [15:0] bit_phase;
  logic        [31:0] hist;
  logic               pre_window, win_started, win_frozen;
  logic        [15:0] win_cnt, win_trans, win_cnt_snap;
  logic signed [31:0] win_fsum, win_fsum_snap;
  logic        [7:0]  byte_sh, byte_cnt, pkts_in_burst;
  logic        [2:0]  bit_in_byte;
  logic        [15:0] crc;

  wire signed [15:0] favg16 = favg[23:8];

  //-------------------------------------------- комбінаційний наступний крок
  logic               bit_now, trans;
  logic signed [15:0] ph_err;
  logic        [15:0] ph_corr;
  logic        [16:0] ph_sum;
  logic               wrap;
  logic        [31:0] hist_n;
  logic        [15:0] h16;
  logic               alt8;
  logic        [7:0]  byte_n;
  logic        [15:0] crc_n;
  logic               crc_fb;

  assign bit_now = (in_dphi > favg16) ^ inverted;
  assign trans   = bit_now != bit_prev;

  assign ph_err  = bit_phase - 16'h8000;
  // Знакові зсуви -- окремими сигналами: у виразі з беззнаковим bit_phase
  // `>>>` став би логічним, і корекція при від'ємній помилці була б хибною.
  wire signed [15:0] ph_adj = ph_err >>> 2;
  assign ph_corr = trans ? (bit_phase - ph_adj) : bit_phase;
  assign ph_sum  = {1'b0, ph_corr} + {1'b0, cfg_bit_inc};
  assign wrap    = ph_sum[16];

  assign hist_n  = {hist[30:0], bit_now};
  assign h16     = hist_n[15:0];
  assign alt8    = (hist_n[7:0] == 8'hAA) || (hist_n[7:0] == 8'h55);

  assign byte_n  = {byte_sh[6:0], bit_now};
  assign crc_fb  = crc[15] ^ bit_now;
  assign crc_n   = {crc[14:0], 1'b0} ^ (crc_fb ? cfg_crc_poly : 16'h0000);

  wire        afc_fast = in_burst_len < 32'(cfg_fast_len);
  wire [3:0]  afc_sh   = afc_fast ? cfg_sh_fast : cfg_sh_slow;

  wire signed [24:0] favg_d  = 25'(signed'({in_dphi, 8'd0})) - 25'(favg);
  wire signed [23:0] favg_nx = favg + 24'(favg_d >>> afc_sh);

  wire signed [16:0] err_s   = 17'(in_dphi) - 17'(favg16);
  wire        [16:0] err_abs = err_s[16] ? -err_s : err_s;
  wire signed [25:0] dev_d   = 26'($signed({1'b0, err_abs, 8'd0})) - 26'($signed({2'b0, dev}));
  wire signed [25:0] dev_stp = dev_d >>> cfg_dev_shift;
  wire        [23:0] dev_nx  = dev + 24'(dev_stp);

  wire sync_hit   = (h16 == cfg_sync_word);
  wire sync_inv   = (h16 == ~cfg_sync_word);
  wire byte_done  = (bit_in_byte == 3'd7);
  wire pkt_done   = byte_done && (byte_cnt + 1'b1 == cfg_pkt_len);

  //------------------------------------------------------------ результати
  // Поля результату беруться з регістрів стану; строб -- регістр, тож
  // значення дійсні в такті res_strobe (стан ще не очищено -- очищення
  // відбувається тим самим фронтом, але читач бачить старі значення).
  always_comb begin
    res_bytes          = byte_cnt;
    res_bits           = {5'd0, byte_cnt, 3'd0} + 16'(bit_in_byte);
    res_pkts_in_burst  = pkts_in_burst;
    res_win_trans      = win_trans;
    res_win_cnt        = win_cnt_snap;
    res_win_fsum       = win_fsum_snap;
  end

  assign tap_bit_v     = in_valid && in_burst && !in_burst_start && !in_burst_end && wrap;
  assign tap_bit       = bit_now;

  assign st_synced     = synced;
  assign st_pkt_active = pkt_active;
  assign st_preamble   = preamble;
  assign st_inverted   = inverted;
  assign st_favg       = favg16;
  assign st_dev        = dev[23:8];

  //------------------------------------------------------- головний крок --
  always_ff @(posedge clk) begin
    if (rst) begin
      favg <= '0; dev <= '0;
      synced <= 1'b0; inverted <= 1'b0; preamble <= 1'b0; pkt_active <= 1'b0;
      bit_prev <= 1'b0; bit_phase <= '0; hist <= '0;
      pre_window <= 1'b0; win_started <= 1'b0; win_frozen <= 1'b0;
      win_cnt <= '0; win_trans <= '0; win_cnt_snap <= '0;
      win_fsum <= '0; win_fsum_snap <= '0;
      byte_sh <= '0; byte_cnt <= '0; pkts_in_burst <= '0; bit_in_byte <= '0;
      crc <= '0;
      pkt_we <= 1'b0; pkt_waddr <= '0; pkt_wdata <= '0;
      res_strobe <= 1'b0; res_kind <= 2'd0; res_crc_ok <= 1'b0;
    end
    else begin
      pkt_we     <= 1'b0;
      res_strobe <= 1'b0;

      if (in_valid) begin
        //------------------------------------------------ початок пакета
        if (in_burst_start) begin
          favg          <= {cfg_freq_init, 8'd0};
          dev           <= '0;
          synced        <= 1'b0;
          inverted      <= 1'b0;
          preamble      <= 1'b0;
          pkt_active    <= 1'b0;
          pkts_in_burst <= '0;
          hist          <= '0;
          pre_window    <= 1'b0;
          win_started   <= 1'b0;
          win_frozen    <= 1'b0;
          win_cnt       <= '0;
          win_trans     <= '0;
          win_fsum      <= '0;
          win_cnt_snap  <= '0;
          win_fsum_snap <= '0;
          bit_phase     <= '0;
          bit_prev      <= 1'b0;
        end
        //-------------------------------------------------- кінець пакета
        else if (in_burst_end) begin
          if (pkt_active) begin
            res_strobe <= 1'b1;
            res_kind   <= 2'd2;
            res_crc_ok <= 1'b0;
          end
          else if (!synced && pkts_in_burst == 0) begin
            res_strobe <= 1'b1;
            res_kind   <= 2'd1;
            res_crc_ok <= 1'b0;
          end
          pkt_active <= 1'b0;
          synced     <= 1'b0;
        end
        //----------------------------------------------- відлік у пакеті
        else if (in_burst) begin
          // AFC і девіація -- лише до sync
          if (!synced) begin
            favg <= favg_nx;
            dev  <= dev_nx;
          end
          bit_prev <= bit_now;

          // вікно вимірювання
          if (!synced && pre_window && !win_frozen) begin
            if (trans && !win_started) begin
              win_started <= 1'b1;
              win_cnt     <= 16'd1;
              win_trans   <= '0;
              win_fsum    <= 32'(in_dphi);
            end
            else if (win_started) begin
              if (trans) begin
                win_trans     <= win_trans + 1'b1;
                win_cnt_snap  <= win_cnt;
                win_fsum_snap <= win_fsum;
              end
              if (win_cnt != 16'hFFFF) win_cnt <= win_cnt + 1'b1;
              win_fsum <= win_fsum + 32'(in_dphi);
            end
          end

          // бітовий NCO
          bit_phase <= ph_sum[15:0];

          if (wrap) begin
            hist <= hist_n;
            if (!synced) begin
              if (win_started && !alt8) win_frozen <= 1'b1;
              pre_window <= alt8;
              if (h16 == 16'hAAAA || h16 == 16'h5555) preamble <= 1'b1;
              if (sync_hit || sync_inv) begin
                if (sync_inv) inverted <= ~inverted;
                synced      <= 1'b1;
                pkt_active  <= 1'b1;
                byte_sh     <= '0;
                bit_in_byte <= '0;
                byte_cnt    <= '0;
                crc         <= cfg_crc_init;
              end
            end
            else if (pkt_active) begin
              byte_sh     <= byte_n;
              crc         <= crc_n;
              bit_in_byte <= bit_in_byte + 1'b1;
              if (byte_done) begin
                bit_in_byte <= '0;
                byte_cnt    <= byte_cnt + 1'b1;
                pkt_we      <= 1'b1;
                pkt_waddr   <= byte_cnt;
                pkt_wdata   <= byte_n;
                if (pkt_done) begin
                  pkts_in_burst <= pkts_in_burst + 1'b1;
                  res_strobe    <= 1'b1;
                  res_kind      <= 2'd0;
                  res_crc_ok    <= (crc_n == cfg_crc_residue);
                  pkt_active    <= 1'b0;
                  synced        <= 1'b0;
                end
              end
            end
          end
        end
      end
    end
  end

endmodule
