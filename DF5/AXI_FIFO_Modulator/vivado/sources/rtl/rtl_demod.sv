//==============================================================================
// rtl_demod -- ядро 2-FSK/GFSK демодулятора для записаного I/Q.
//
//   AXI-Stream I/Q  ->  NCO-мікшер  ->  CIC3 /R  ->  дискримінатор (CORDIC)
//                  ->  потужність / детектор пакета  ->  слайсер + такти
//                  ->  sync  ->  байти  ->  CRC  ->  результат + пам'ять пакета
//
// Швидкість обробки: один вхідний відлік за такт; реальний темп задає
// MicroBlaze (replay із SD), алгоритм від нього не залежить -- усе
// рахується "на відлік", а не "на секунду". Герци відновлює софт за Fs/R.
//
// Усі параметри -- регістри (див. rtl_demod_regs.sv).
//==============================================================================
module rtl_demod #(
  parameter LUT_FILE = "nco_sin_1024.mem"
)(
  input  logic               clk,
  input  logic               rst,            // синхронний, активний 1

  // вхідний потік {Q[31:16], I[15:0]}
  input  logic               s_valid,
  output logic               s_ready,
  input  logic [31:0]        s_data,

  // конфігурація
  input  logic               cfg_enable,
  input  logic [31:0]        cfg_nco_inc,
  input  logic [7:0]         cfg_decim,
  input  logic [4:0]         cfg_cic_shift,
  input  logic [31:0]        cfg_burst_thr,
  input  logic [15:0]        cfg_bit_inc,
  input  logic [15:0]        cfg_sync_word,
  input  logic [7:0]         cfg_pkt_len,
  input  logic [15:0]        cfg_crc_poly,
  input  logic [15:0]        cfg_crc_init,
  input  logic [15:0]        cfg_crc_residue,
  input  logic [15:0]        cfg_freq_init,
  input  logic [3:0]         cfg_sh_fast,
  input  logic [3:0]         cfg_sh_slow,
  input  logic [15:0]        cfg_fast_len,
  input  logic [3:0]         cfg_dev_shift,

  // живий стан
  output logic               st_burst,
  output logic               st_synced,
  output logic               st_pkt_active,
  output logic               st_preamble,
  output logic               st_inverted,
  output logic               st_warmup_done,
  output logic [31:0]        st_pavg,
  output logic [31:0]        st_noise,
  output logic [31:0]        st_thr_on,
  output logic signed [15:0] st_favg,
  output logic [15:0]        st_dev,
  output logic [31:0]        st_in_count,
  output logic [31:0]        st_dec_count,
  output logic               ev_burst_start,

  // поточні вимірювання пакета (для защіпки результату)
  output logic [31:0]        m_burst_len,
  output logic [31:0]        m_burst_peak,
  output logic [31:0]        m_burst_pwr,

  // результат
  output logic               res_strobe,
  output logic [1:0]         res_kind,
  output logic               res_crc_ok,
  output logic [15:0]        res_bits,
  output logic [7:0]         res_bytes,
  output logic [7:0]         res_pkts_in_burst,
  output logic [15:0]        res_win_trans,
  output logic [15:0]        res_win_cnt,
  output logic signed [31:0] res_win_fsum,

  // відводи для захоплення (dsp_capture): децимований потік після детектора
  output logic               tap_v,          // децимований відлік
  output logic               tap_burst,
  output logic               tap_start,
  output logic               tap_end,
  output logic               tap_bit_v,      // бітове рішення в пакеті
  output logic               tap_bit,

  // пам'ять пакета
  output logic               pkt_we,
  output logic [7:0]         pkt_waddr,
  output logic [7:0]         pkt_wdata
);

  // Без enable потік стоїть у FIFO -- так софт встигає сконфігурувати ядро.
  assign s_ready = cfg_enable;
  wire   in_fire = s_valid && cfg_enable;

  always_ff @(posedge clk) begin
    if (rst) st_in_count <= '0;
    else if (in_fire) st_in_count <= st_in_count + 1'b1;
  end

  //----------------------------------------------------------- мікшер -----
  logic               mix_v;
  logic signed [15:0] mix_i, mix_q;

  demod_nco_mixer #(.LUT_FILE(LUT_FILE)) u_mix (
    .clk (clk), .rst (rst),
    .nco_inc   (cfg_nco_inc),
    .in_valid  (in_fire),
    .in_i      (s_data[15:0]),
    .in_q      (s_data[31:16]),
    .out_valid (mix_v),
    .out_i     (mix_i),
    .out_q     (mix_q)
  );

  //--------------------------------------------------------------- CIC ----
  logic               dec_v;
  logic signed [15:0] dec_i, dec_q;

  demod_cic3 u_cic (
    .clk (clk), .rst (rst),
    .decim     (cfg_decim),
    .shift     (cfg_cic_shift),
    .in_valid  (mix_v),
    .in_i      (mix_i),
    .in_q      (mix_q),
    .out_valid (dec_v),
    .out_i     (dec_i),
    .out_q     (dec_q)
  );

  always_ff @(posedge clk) begin
    if (rst) st_dec_count <= '0;
    else if (dec_v) st_dec_count <= st_dec_count + 1'b1;
  end

  //------------------------------------------------------ дискримінатор ---
  logic               dsc_v;
  logic signed [15:0] dsc_dphi, dsc_i, dsc_q;

  demod_discriminator u_disc (
    .clk (clk), .rst (rst),
    .in_valid  (dec_v),
    .in_i      (dec_i),
    .in_q      (dec_q),
    .out_valid (dsc_v),
    .out_dphi  (dsc_dphi),
    .out_i     (dsc_i),
    .out_q     (dsc_q)
  );

  //------------------------------------------------- потужність / burst ---
  logic               pw_v, pw_burst, pw_start, pw_end;
  logic signed [15:0] pw_dphi;

  demod_power u_pw (
    .clk (clk), .rst (rst),
    .burst_thr   (cfg_burst_thr),
    .in_valid    (dsc_v),
    .in_i        (dsc_i),
    .in_q        (dsc_q),
    .in_dphi     (dsc_dphi),
    .out_valid   (pw_v),
    .out_dphi    (pw_dphi),
    .burst       (pw_burst),
    .burst_start (pw_start),
    .burst_end   (pw_end),
    .pavg        (st_pavg),
    .noise       (st_noise),
    .thr_on      (st_thr_on),
    .warmup_done (st_warmup_done),
    .burst_len   (m_burst_len),
    .burst_peak  (m_burst_peak),
    .burst_pwr   (m_burst_pwr)
  );

  assign st_burst       = pw_burst;
  assign tap_v          = pw_v;
  assign tap_burst      = pw_burst;
  assign tap_start      = pw_start;
  assign tap_end        = pw_end;
  assign ev_burst_start = pw_v && pw_start;

  //--------------------------------------------------------- біти ---------
  demod_bit_decoder u_bits (
    .clk (clk), .rst (rst),
    .cfg_freq_init   (cfg_freq_init),
    .cfg_sh_fast     (cfg_sh_fast),
    .cfg_sh_slow     (cfg_sh_slow),
    .cfg_fast_len    (cfg_fast_len),
    .cfg_dev_shift   (cfg_dev_shift),
    .cfg_bit_inc     (cfg_bit_inc),
    .cfg_sync_word   (cfg_sync_word),
    .cfg_pkt_len     (cfg_pkt_len),
    .cfg_crc_poly    (cfg_crc_poly),
    .cfg_crc_init    (cfg_crc_init),
    .cfg_crc_residue (cfg_crc_residue),
    .in_valid        (pw_v),
    .in_dphi         (pw_dphi),
    .in_burst        (pw_burst),
    .in_burst_start  (pw_start),
    .in_burst_end    (pw_end),
    .in_burst_len    (m_burst_len),
    .tap_bit_v       (tap_bit_v),
    .tap_bit         (tap_bit),
    .pkt_we          (pkt_we),
    .pkt_waddr       (pkt_waddr),
    .pkt_wdata       (pkt_wdata),
    .st_synced       (st_synced),
    .st_pkt_active   (st_pkt_active),
    .st_preamble     (st_preamble),
    .st_inverted     (st_inverted),
    .st_favg         (st_favg),
    .st_dev          (st_dev),
    .res_strobe      (res_strobe),
    .res_kind        (res_kind),
    .res_crc_ok      (res_crc_ok),
    .res_bits        (res_bits),
    .res_bytes       (res_bytes),
    .res_pkts_in_burst (res_pkts_in_burst),
    .res_win_trans   (res_win_trans),
    .res_win_cnt     (res_win_cnt),
    .res_win_fsum    (res_win_fsum)
  );

endmodule
