//==============================================================================
// tb_fsk_demod_plot
//
// Data-capture testbench for tools/plot_rtl_demod.py.  It reads an interleaved
// int16 I/Q file, streams it into fsk_demod_top, and writes a cycle-by-cycle CSV
// with the input and every visible DSP stage.
//
// Plusargs:
//   +IQ_FILE=<path>
//   +CSV_FILE=<path>
//   +NCO_INC=<hex>
//   +DECIM=<int>
//   +CIC_SHIFT=<int>
//   +BIT_INC=<int>
//   +PKT_LEN=<int>
//   +MAX_SAMPLES=<int>     0 means whole file
//==============================================================================
module tb_fsk_demod_plot;

  localparam time CLK_P = 10;

  string iq_file  = "../../../../sources/sim_data/sim_plot.iq";
  string csv_file = "../../../../sources/sim_data/rtl_plot.csv";

  int unsigned max_samples = 0;

  logic clk = 1'b0;
  logic rst;
  always #(CLK_P/2) clk = ~clk;

  logic        s_valid, s_ready;
  logic [31:0] s_data;

  logic               cfg_enable;
  logic [31:0]        cfg_nco_inc;
  logic [7:0]         cfg_decim;
  logic [4:0]         cfg_cic_shift;
  logic [31:0]        cfg_burst_thr;
  logic [15:0]        cfg_bit_inc;
  logic [15:0]        cfg_sync_word;
  logic [7:0]         cfg_pkt_len;
  logic [15:0]        cfg_crc_poly;
  logic [15:0]        cfg_crc_init;
  logic [15:0]        cfg_crc_residue;
  logic [15:0]        cfg_freq_init;
  logic [3:0]         cfg_sh_fast;
  logic [3:0]         cfg_sh_slow;
  logic [15:0]        cfg_fast_len;
  logic [3:0]         cfg_dev_shift;

  logic               st_burst, st_synced, st_pkt_active, st_preamble;
  logic               st_inverted, st_warmup_done, ev_burst_start;
  logic [31:0]        st_pavg, st_noise, st_thr_on, st_in_count, st_dec_count;
  logic signed [15:0] st_favg;
  logic [15:0]        st_dev;
  logic [31:0]        m_burst_len, m_burst_peak, m_burst_pwr;
  logic               res_strobe, res_crc_ok;
  logic [1:0]         res_kind;
  logic [15:0]        res_bits, res_win_trans, res_win_cnt;
  logic [7:0]         res_bytes, res_pkts_in_burst;
  logic signed [31:0] res_win_fsum;
  logic               pkt_we;
  logic [7:0]         pkt_waddr, pkt_wdata;

  logic               dbg_mix_valid, dbg_dec_valid, dbg_dsc_valid, dbg_pw_valid;
  logic signed [15:0] dbg_mix_i, dbg_mix_q, dbg_dec_i, dbg_dec_q;
  logic signed [15:0] dbg_dsc_dphi, dbg_dsc_i, dbg_dsc_q, dbg_pw_dphi;
  logic               dbg_pw_burst, dbg_pw_burst_start, dbg_pw_burst_end;

  fsk_demod_top u_dut (
    .clk(clk), .rst(rst),
    .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
    .cfg_enable(cfg_enable),
    .cfg_nco_inc(cfg_nco_inc),
    .cfg_decim(cfg_decim),
    .cfg_cic_shift(cfg_cic_shift),
    .cfg_burst_thr(cfg_burst_thr),
    .cfg_bit_inc(cfg_bit_inc),
    .cfg_sync_word(cfg_sync_word),
    .cfg_pkt_len(cfg_pkt_len),
    .cfg_crc_poly(cfg_crc_poly),
    .cfg_crc_init(cfg_crc_init),
    .cfg_crc_residue(cfg_crc_residue),
    .cfg_freq_init(cfg_freq_init),
    .cfg_sh_fast(cfg_sh_fast),
    .cfg_sh_slow(cfg_sh_slow),
    .cfg_fast_len(cfg_fast_len),
    .cfg_dev_shift(cfg_dev_shift),
    .st_burst(st_burst),
    .st_synced(st_synced),
    .st_pkt_active(st_pkt_active),
    .st_preamble(st_preamble),
    .st_inverted(st_inverted),
    .st_warmup_done(st_warmup_done),
    .st_pavg(st_pavg),
    .st_noise(st_noise),
    .st_thr_on(st_thr_on),
    .st_favg(st_favg),
    .st_dev(st_dev),
    .st_in_count(st_in_count),
    .st_dec_count(st_dec_count),
    .ev_burst_start(ev_burst_start),
    .m_burst_len(m_burst_len),
    .m_burst_peak(m_burst_peak),
    .m_burst_pwr(m_burst_pwr),
    .res_strobe(res_strobe),
    .res_kind(res_kind),
    .res_crc_ok(res_crc_ok),
    .res_bits(res_bits),
    .res_bytes(res_bytes),
    .res_pkts_in_burst(res_pkts_in_burst),
    .res_win_trans(res_win_trans),
    .res_win_cnt(res_win_cnt),
    .res_win_fsum(res_win_fsum),
    .pkt_we(pkt_we),
    .pkt_waddr(pkt_waddr),
    .pkt_wdata(pkt_wdata),
    .dbg_mix_valid(dbg_mix_valid),
    .dbg_mix_i(dbg_mix_i),
    .dbg_mix_q(dbg_mix_q),
    .dbg_dec_valid(dbg_dec_valid),
    .dbg_dec_i(dbg_dec_i),
    .dbg_dec_q(dbg_dec_q),
    .dbg_dsc_valid(dbg_dsc_valid),
    .dbg_dsc_dphi(dbg_dsc_dphi),
    .dbg_dsc_i(dbg_dsc_i),
    .dbg_dsc_q(dbg_dsc_q),
    .dbg_pw_valid(dbg_pw_valid),
    .dbg_pw_dphi(dbg_pw_dphi),
    .dbg_pw_burst(dbg_pw_burst),
    .dbg_pw_burst_start(dbg_pw_burst_start),
    .dbg_pw_burst_end(dbg_pw_burst_end)
  );

  function automatic int b01(input logic v);
    return (v === 1'b1) ? 1 : 0;
  endfunction

  int csv_fd;
  longint unsigned cycle;

  always_ff @(posedge clk) begin
    if (rst) begin
      cycle <= 0;
    end
    else begin
      cycle <= cycle + 1;
      if (csv_fd != 0) begin
        $fdisplay(csv_fd,
          "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
          cycle,
          b01(s_valid && s_ready),
          $signed(s_data[15:0]),
          $signed(s_data[31:16]),
          b01(dbg_mix_valid),
          b01(dbg_mix_valid) ? $signed(dbg_mix_i) : 0,
          b01(dbg_mix_valid) ? $signed(dbg_mix_q) : 0,
          b01(dbg_dec_valid),
          b01(dbg_dec_valid) ? $signed(dbg_dec_i) : 0,
          b01(dbg_dec_valid) ? $signed(dbg_dec_q) : 0,
          b01(dbg_dsc_valid),
          b01(dbg_dsc_valid) ? $signed(dbg_dsc_dphi) : 0,
          b01(dbg_dsc_valid) ? $signed(dbg_dsc_i) : 0,
          b01(dbg_dsc_valid) ? $signed(dbg_dsc_q) : 0,
          b01(dbg_pw_valid),
          b01(dbg_pw_valid) ? $signed(dbg_pw_dphi) : 0,
          b01(dbg_pw_burst),
          b01(dbg_pw_burst_start),
          b01(dbg_pw_burst_end),
          st_pavg,
          st_noise,
          st_thr_on,
          b01(st_warmup_done),
          $signed(st_favg),
          st_dev,
          b01(st_synced),
          b01(st_preamble),
          b01(st_pkt_active),
          st_in_count,
          st_dec_count,
          m_burst_len,
          m_burst_peak,
          m_burst_pwr,
          b01(res_strobe),
          res_kind,
          b01(res_crc_ok),
          res_bits,
          res_bytes);
      end
    end
  end

  initial begin
    int fd, cfg_fd, rc;
    int n_samples, n_drive, n_bytes, byte_v;
    logic [7:0] iq_bytes [];
    int unsigned tmp;
    int unsigned nco_tmp, decim_tmp, cic_shift_tmp, bit_inc_tmp, pkt_len_tmp, max_samples_tmp;
    int dummy;

    s_valid <= 1'b0;
    s_data  <= '0;

    cfg_enable      = 1'b0;
    cfg_nco_inc     = 32'h3E02_468B;
    cfg_decim       = 8'd16;
    cfg_cic_shift   = 5'd12;
    cfg_burst_thr   = 32'd0;
    cfg_bit_inc     = 16'd4475;
    cfg_sync_word   = 16'h91D3;
    cfg_pkt_len     = 8'd48;
    cfg_crc_poly    = 16'h1021;
    cfg_crc_init    = 16'hFFFF;
    cfg_crc_residue = 16'h0000;
    cfg_freq_init   = 16'd0;
    cfg_sh_fast     = 4'd4;
    cfg_sh_slow     = 4'd7;
    cfg_fast_len    = 16'd128;
    cfg_dev_shift   = 4'd5;

    dummy = $value$plusargs("IQ_FILE=%s", iq_file);
    dummy = $value$plusargs("CSV_FILE=%s", csv_file);
    if ($value$plusargs("NCO_INC=%h", tmp))   cfg_nco_inc   = tmp;
    if ($value$plusargs("DECIM=%d", tmp))     cfg_decim     = tmp[7:0];
    if ($value$plusargs("CIC_SHIFT=%d", tmp)) cfg_cic_shift = tmp[4:0];
    if ($value$plusargs("BIT_INC=%d", tmp))   cfg_bit_inc   = tmp[15:0];
    if ($value$plusargs("PKT_LEN=%d", tmp))   cfg_pkt_len   = tmp[7:0];
    if ($value$plusargs("MAX_SAMPLES=%d", tmp)) max_samples = tmp;

    cfg_fd = $fopen("plot_run_args.txt", "r");
    if (cfg_fd != 0) begin
      rc = $fscanf(cfg_fd, "%s\n", iq_file);
      rc = $fscanf(cfg_fd, "%s\n", csv_file);
      rc = $fscanf(cfg_fd, "%h %d %d %d %d %d\n",
                   nco_tmp, decim_tmp, cic_shift_tmp,
                   bit_inc_tmp, pkt_len_tmp, max_samples_tmp);
      cfg_nco_inc   = nco_tmp;
      cfg_decim     = decim_tmp[7:0];
      cfg_cic_shift = cic_shift_tmp[4:0];
      cfg_bit_inc   = bit_inc_tmp[15:0];
      cfg_pkt_len   = pkt_len_tmp[7:0];
      max_samples   = max_samples_tmp;
      $fclose(cfg_fd);
      $display("Loaded plot_run_args.txt");
      $display("CFG: rc=%0d nco=0x%08h decim=%0d cic_shift=%0d bit_inc=%0d pkt_len=%0d max_samples=%0d",
               rc, cfg_nco_inc, cfg_decim, cfg_cic_shift, cfg_bit_inc, cfg_pkt_len, max_samples);
    end

    csv_fd = $fopen(csv_file, "w");
    if (csv_fd == 0) begin
      $error("Cannot open CSV_FILE=%s", csv_file);
      $finish;
    end
    $fdisplay(csv_fd,
      "cycle,in_valid,in_i,in_q,mix_valid,mix_i,mix_q,dec_valid,dec_i,dec_q,dsc_valid,dphi,dsc_i,dsc_q,pw_valid,pw_dphi,burst,burst_start,burst_end,pavg,noise,thr_on,warmup_done,favg,dev,synced,preamble,pkt_active,in_count,dec_count,burst_len,burst_peak,burst_pwr,res_strobe,res_kind,res_crc_ok,res_bits,res_bytes");

    fd = $fopen(iq_file, "rb");
    if (fd == 0) begin
      $error("Cannot open IQ_FILE=%s", iq_file);
      $finish;
    end
    rc = $fseek(fd, 0, 2);
    n_samples = $ftell(fd) / 4;
    rc = $fseek(fd, 0, 0);
    if (max_samples > 0)
      n_samples = int'(max_samples);
    $display("LIMIT: n_samples=%0d", n_samples);
    iq_bytes = new[n_samples * 4];
    n_bytes = 0;
    for (int b = 0; b < n_samples * 4; b++) begin
      byte_v = $fgetc(fd);
      if (byte_v < 0)
        break;
      iq_bytes[b] = byte_v[7:0];
      n_bytes++;
    end
    $fclose(fd);
    n_drive = n_bytes / 4;
    $display("IQ: %s, read %0d bytes = %0d samples", iq_file, n_bytes, n_drive);
    $display("CSV: %s", csv_file);

    rst = 1'b1;
    repeat (8) @(posedge clk);
    rst = 1'b0;
    repeat (4) @(posedge clk);
    cfg_enable <= 1'b1;

    for (int k = 0; k < n_drive; k++) begin
      s_data  <= {iq_bytes[4*k+3], iq_bytes[4*k+2], iq_bytes[4*k+1], iq_bytes[4*k+0]};
      s_valid <= 1'b1;
      do @(posedge clk); while (!s_ready);
      s_valid <= 1'b0;
      @(posedge clk);
    end

    repeat (2000) @(posedge clk);
    $display("DONE: in_count=%0d dec_count=%0d", st_in_count, st_dec_count);
    $fclose(csv_fd);
    $finish;
  end

  initial begin
    #(CLK_P * 5_000_000);
    $error("Watchdog timeout");
    if (csv_fd != 0) $fclose(csv_fd);
    $finish;
  end

endmodule
