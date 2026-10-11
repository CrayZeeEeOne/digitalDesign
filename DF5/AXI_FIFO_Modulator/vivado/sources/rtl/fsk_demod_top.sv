//==============================================================================
// fsk_demod_top
//
// Synthesizable top for the DF5 2-FSK/GFSK demodulator datapath.  It keeps the
// same algorithmic chain as rtl_demod.sv, but exposes stage-level debug signals
// so a simulation harness can plot every important component:
//
//   input I/Q -> NCO mixer -> CIC3 -> FM discriminator -> power/burst
//             -> bit/packet decoder
//
// This module is intentionally register/stream oriented.  For MicroBlaze AXI
// integration use rtl_demod_regs/rtl_demod_top; for DSP bring-up and plotting
// use this top directly.
//==============================================================================
module fsk_demod_top #(
  parameter LUT_FILE = "nco_sin_1024.mem"
)(
  input  logic               clk,
  input  logic               rst,            // synchronous, active high

  // Input stream: {Q[31:16], I[15:0]}.
  input  logic               s_valid,
  output logic               s_ready,
  input  logic [31:0]        s_data,

  // Configuration.
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

  // Live status.
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

  // Current burst measurements.
  output logic [31:0]        m_burst_len,
  output logic [31:0]        m_burst_peak,
  output logic [31:0]        m_burst_pwr,

  // Decoded result.
  output logic               res_strobe,
  output logic [1:0]         res_kind,
  output logic               res_crc_ok,
  output logic [15:0]        res_bits,
  output logic [7:0]         res_bytes,
  output logic [7:0]         res_pkts_in_burst,
  output logic [15:0]        res_win_trans,
  output logic [15:0]        res_win_cnt,
  output logic signed [31:0] res_win_fsum,

  // Packet byte write port.
  output logic               pkt_we,
  output logic [7:0]         pkt_waddr,
  output logic [7:0]         pkt_wdata,

  // Stage debug: mixer.
  output logic               dbg_mix_valid,
  output logic signed [15:0] dbg_mix_i,
  output logic signed [15:0] dbg_mix_q,

  // Stage debug: CIC/decimator.
  output logic               dbg_dec_valid,
  output logic signed [15:0] dbg_dec_i,
  output logic signed [15:0] dbg_dec_q,

  // Stage debug: discriminator.
  output logic               dbg_dsc_valid,
  output logic signed [15:0] dbg_dsc_dphi,
  output logic signed [15:0] dbg_dsc_i,
  output logic signed [15:0] dbg_dsc_q,

  // Stage debug: power/burst detector.
  output logic               dbg_pw_valid,
  output logic signed [15:0] dbg_pw_dphi,
  output logic               dbg_pw_burst,
  output logic               dbg_pw_burst_start,
  output logic               dbg_pw_burst_end
);

  assign s_ready = cfg_enable;
  wire in_fire = s_valid && cfg_enable;

  always_ff @(posedge clk) begin
    if (rst)          st_in_count <= '0;
    else if (in_fire) st_in_count <= st_in_count + 1'b1;
  end

  //--------------------------------------------------------------------------
  // NCO mixer.
  //--------------------------------------------------------------------------
  demod_nco_mixer #(.LUT_FILE(LUT_FILE)) u_mix (
    .clk       (clk),
    .rst       (rst),
    .nco_inc   (cfg_nco_inc),
    .in_valid  (in_fire),
    .in_i      (s_data[15:0]),
    .in_q      (s_data[31:16]),
    .out_valid (dbg_mix_valid),
    .out_i     (dbg_mix_i),
    .out_q     (dbg_mix_q)
  );

  //--------------------------------------------------------------------------
  // CIC decimator.
  //--------------------------------------------------------------------------
  demod_cic3 u_cic (
    .clk       (clk),
    .rst       (rst),
    .decim     (cfg_decim),
    .shift     (cfg_cic_shift),
    .in_valid  (dbg_mix_valid),
    .in_i      (dbg_mix_i),
    .in_q      (dbg_mix_q),
    .out_valid (dbg_dec_valid),
    .out_i     (dbg_dec_i),
    .out_q     (dbg_dec_q)
  );

  always_ff @(posedge clk) begin
    if (rst)              st_dec_count <= '0;
    else if (dbg_dec_valid) st_dec_count <= st_dec_count + 1'b1;
  end

  //--------------------------------------------------------------------------
  // FM discriminator.
  //--------------------------------------------------------------------------
  demod_discriminator u_disc (
    .clk       (clk),
    .rst       (rst),
    .in_valid  (dbg_dec_valid),
    .in_i      (dbg_dec_i),
    .in_q      (dbg_dec_q),
    .out_valid (dbg_dsc_valid),
    .out_dphi  (dbg_dsc_dphi),
    .out_i     (dbg_dsc_i),
    .out_q     (dbg_dsc_q)
  );

  //--------------------------------------------------------------------------
  // Power and burst detector.
  //--------------------------------------------------------------------------
  demod_power u_pw (
    .clk         (clk),
    .rst         (rst),
    .burst_thr   (cfg_burst_thr),
    .in_valid    (dbg_dsc_valid),
    .in_i        (dbg_dsc_i),
    .in_q        (dbg_dsc_q),
    .in_dphi     (dbg_dsc_dphi),
    .out_valid   (dbg_pw_valid),
    .out_dphi    (dbg_pw_dphi),
    .burst       (dbg_pw_burst),
    .burst_start (dbg_pw_burst_start),
    .burst_end   (dbg_pw_burst_end),
    .pavg        (st_pavg),
    .noise       (st_noise),
    .thr_on      (st_thr_on),
    .warmup_done (st_warmup_done),
    .burst_len   (m_burst_len),
    .burst_peak  (m_burst_peak),
    .burst_pwr   (m_burst_pwr)
  );

  assign st_burst       = dbg_pw_burst;
  assign ev_burst_start = dbg_pw_valid && dbg_pw_burst_start;

  //--------------------------------------------------------------------------
  // Bit and packet decoder.
  //--------------------------------------------------------------------------
  demod_bit_decoder u_bits (
    .clk              (clk),
    .rst              (rst),
    .cfg_freq_init    (cfg_freq_init),
    .cfg_sh_fast      (cfg_sh_fast),
    .cfg_sh_slow      (cfg_sh_slow),
    .cfg_fast_len     (cfg_fast_len),
    .cfg_dev_shift    (cfg_dev_shift),
    .cfg_bit_inc      (cfg_bit_inc),
    .cfg_sync_word    (cfg_sync_word),
    .cfg_pkt_len      (cfg_pkt_len),
    .cfg_crc_poly     (cfg_crc_poly),
    .cfg_crc_init     (cfg_crc_init),
    .cfg_crc_residue  (cfg_crc_residue),
    .in_valid         (dbg_pw_valid),
    .in_dphi          (dbg_pw_dphi),
    .in_burst         (dbg_pw_burst),
    .in_burst_start   (dbg_pw_burst_start),
    .in_burst_end     (dbg_pw_burst_end),
    .in_burst_len     (m_burst_len),
    .pkt_we           (pkt_we),
    .pkt_waddr        (pkt_waddr),
    .pkt_wdata        (pkt_wdata),
    .st_synced        (st_synced),
    .st_pkt_active    (st_pkt_active),
    .st_preamble      (st_preamble),
    .st_inverted      (st_inverted),
    .st_favg          (st_favg),
    .st_dev           (st_dev),
    .res_strobe       (res_strobe),
    .res_kind         (res_kind),
    .res_crc_ok       (res_crc_ok),
    .res_bits         (res_bits),
    .res_bytes        (res_bytes),
    .res_pkts_in_burst(res_pkts_in_burst),
    .res_win_trans    (res_win_trans),
    .res_win_cnt      (res_win_cnt),
    .res_win_fsum     (res_win_fsum)
  );

endmodule
