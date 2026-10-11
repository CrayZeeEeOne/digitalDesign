//==============================================================================
// rtl_demod_regs -- AXI4-Lite регістри демодулятора + пам'ять пакета.
//
// Мапа (offset від базової адреси, 512 байт):
//
//  Керування / конфігурація (RW):
//   0x000 CTRL        [0] enable      1 = приймати потік і обробляти
//                     [1] soft_reset  W, імпульс: скинути все ядро (і шум)
//                     [2] clr_stats   W, імпульс: обнулити лічильники
//                     [3] ack_result  W, імпульс: зняти RESULT_VALID
//   0x004 STATUS (RO) [0] burst  [1] synced  [2] pkt_active  [3] result_valid
//                     [4] result_overrun  [5] warmup_done  [6] enable
//                     [8] preamble  [9] inverted
//   0x008 NCO_INC     крок фази, 2^32 = 2*pi -> f_nco = NCO_INC/2^32 * Fs
//   0x00C DECIM       [7:0] R (2..32), [12:8] cic_shift (= 3*log2 R)
//   0x010 BURST_THR   поріг pavg; 0 = авто (8 x рівень шуму)
//   0x014 BIT_INC     [15:0] крок бітового NCO = Rb / (Fs/R) * 65536
//   0x018 SYNC_WORD   [15:0]
//   0x01C PKT_LEN     [7:0] байтів після sync разом із CRC (1..255)
//   0x020 CRC_CFG     [15:0] поліном, [31:16] початкове значення
//   0x024 CRC_RESIDUE [15:0] очікуваний залишок після всього пакета
//   0x028 FREQ_INIT   [15:0] початковий поріг слайсера (Q15 кут)
//   0x02C AFC_CFG     [3:0] зсув швидкого IIR, [7:4] повільного,
//                     [11:8] зсув IIR девіації, [31:16] довжина швидкої фази
//  Живі вимірювання (RO):
//   0x030 NOISE_FLOOR   0x034 PAVG   0x038 THR_ON
//   0x03C IN_COUNT      0x040 DEC_COUNT
//   0x044 FAVG_DEV      [15:0] поточний поріг слайсера, [31:16] девіація
//  Лічильники (RO, clr_stats):
//   0x048 BURST_COUNT  0x04C PKT_COUNT  0x050 CRC_OK_COUNT  0x054 CRC_ERR_COUNT
//  Защіпнутий результат (RO, дійсний поки RESULT_VALID):
//   0x060 RES_FLAGS   [0] burst(=1) [1] preamble [2] sync [3] crc_ok
//                     [4] inverted [5] truncated [7:6] kind
//                     [15:8] пакетів у цьому burst  [31:16] біт прийнято
//   0x064 RES_BURST_LEN   0x068 RES_BURST_PWR   0x06C RES_BURST_PEAK
//   0x070 RES_NOISE       0x074 RES_FAVG_DEV ([15:0] favg, [31:16] dev)
//   0x078 RES_WIN         [15:0] переходів, [31:16] відліків у вікні
//   0x07C RES_WIN_FSUM    сума dphi у вікні (знакова)
//   0x080 RES_BYTES       [7:0] байтів у пам'яті пакета
//   0x0FC ID              0x4453_4D01 ("DSM" 01)
//  Пам'ять пакета (RO): 0x100..0x1FF -- байти пакета, 4 на слово, перший
//                       байт у бітах [7:0] слова 0x100.
//
// Перерахунок у герци (софт, Fs_dec = Fs / R):
//   f_residual = fsum / cnt / 32768 * Fs_dec / 2     (точна, з вікна)
//   f_slicer   = favg / 32768 * Fs_dec / 2            (груба, з AFC)
//   deviation  = dev  / 32768 * Fs_dec / 2
//   bitrate    = Fs_dec * trans / cnt
//   SNR        = 10*log10((burst_pwr - noise) / noise)
//==============================================================================
module rtl_demod_regs #(
  parameter int          C_S_AXI_ADDR_WIDTH = 9,
  parameter logic [31:0] ID_VALUE           = 32'h4453_4D01,
  parameter              LUT_FILE           = "nco_sin_1024.mem"
)(
  input  logic                          s_axi_aclk,
  input  logic                          s_axi_aresetn,

  input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic [2:0]                    s_axi_awprot,
  input  logic                          s_axi_awvalid,
  output logic                          s_axi_awready,
  input  logic [31:0]                   s_axi_wdata,
  input  logic [3:0]                    s_axi_wstrb,
  input  logic                          s_axi_wvalid,
  output logic                          s_axi_wready,
  output logic [1:0]                    s_axi_bresp,
  output logic                          s_axi_bvalid,
  input  logic                          s_axi_bready,
  input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic [2:0]                    s_axi_arprot,
  input  logic                          s_axi_arvalid,
  output logic                          s_axi_arready,
  output logic [31:0]                   s_axi_rdata,
  output logic [1:0]                    s_axi_rresp,
  output logic                          s_axi_rvalid,
  input  logic                          s_axi_rready,

  input  logic                          s_axis_tvalid,
  output logic                          s_axis_tready,
  input  logic [31:0]                   s_axis_tdata,

  output logic                          irq            // RESULT_VALID (на майбутнє)
);

  //------------------------------------------------------------ міст AXI ---
  logic                          wr_en, rd_en;
  logic [C_S_AXI_ADDR_WIDTH-1:0] wr_addr, rd_addr;
  logic [31:0]                   wr_data, rd_data;
  logic [3:0]                    wr_strb;

  axi_lite_regs #(.ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)) u_axi (
    .s_axi_aclk, .s_axi_aresetn,
    .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,
    .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
    .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
    .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,
    .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .wr_en, .wr_addr, .wr_data, .wr_strb, .rd_en, .rd_addr, .rd_data
  );

  //-------------------------------------------------- регістри керування ---
  logic        cfg_enable, soft_reset, clr_stats, ack_result;
  logic [31:0] cfg_nco_inc;
  logic [7:0]  cfg_decim;
  logic [4:0]  cfg_cic_shift;
  logic [31:0] cfg_burst_thr;
  logic [15:0] cfg_bit_inc;
  logic [15:0] cfg_sync_word;
  logic [7:0]  cfg_pkt_len;
  logic [15:0] cfg_crc_poly, cfg_crc_init, cfg_crc_residue;
  logic [15:0] cfg_freq_init;
  logic [3:0]  cfg_sh_fast, cfg_sh_slow, cfg_dev_shift;
  logic [15:0] cfg_fast_len;

  // Значення після скиду = конфігурація з ТЗ: Fs 4.5 МГц, канал 866.31 при
  // LO 867.4 (NCO +1.09 МГц), R = 16, 19200 бод, sync 0x91D3, 48 байт,
  // CRC-16/CCITT-FALSE.
  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cfg_enable      <= 1'b0;
      soft_reset      <= 1'b0;
      clr_stats       <= 1'b0;
      ack_result      <= 1'b0;
      cfg_nco_inc     <= 32'h3E02_468B;
      cfg_decim       <= 8'd16;
      cfg_cic_shift   <= 5'd12;
      cfg_burst_thr   <= 32'd0;
      cfg_bit_inc     <= 16'd4474;
      cfg_sync_word   <= 16'h91D3;
      cfg_pkt_len     <= 8'd48;
      cfg_crc_poly    <= 16'h1021;
      cfg_crc_init    <= 16'hFFFF;
      cfg_crc_residue <= 16'h0000;
      cfg_freq_init   <= 16'd0;
      cfg_sh_fast     <= 4'd4;
      cfg_sh_slow     <= 4'd7;
      cfg_dev_shift   <= 4'd5;
      cfg_fast_len    <= 16'd128;
    end
    else begin
      soft_reset <= 1'b0;
      clr_stats  <= 1'b0;
      ack_result <= 1'b0;
      if (wr_en) begin
        case (wr_addr)
          9'h000: if (wr_strb[0]) begin
            cfg_enable <= wr_data[0];
            soft_reset <= wr_data[1];
            clr_stats  <= wr_data[2];
            ack_result <= wr_data[3];
          end
          9'h008: cfg_nco_inc <= wr_data;
          9'h00C: begin
            if (wr_strb[0]) cfg_decim     <= wr_data[7:0];
            if (wr_strb[1]) cfg_cic_shift <= wr_data[12:8];
          end
          9'h010: cfg_burst_thr <= wr_data;
          9'h014: cfg_bit_inc   <= wr_data[15:0];
          9'h018: cfg_sync_word <= wr_data[15:0];
          9'h01C: cfg_pkt_len   <= wr_data[7:0];
          9'h020: begin
            cfg_crc_poly <= wr_data[15:0];
            cfg_crc_init <= wr_data[31:16];
          end
          9'h024: cfg_crc_residue <= wr_data[15:0];
          9'h028: cfg_freq_init   <= wr_data[15:0];
          9'h02C: begin
            cfg_sh_fast   <= wr_data[3:0];
            cfg_sh_slow   <= wr_data[7:4];
            cfg_dev_shift <= wr_data[11:8];
            cfg_fast_len  <= wr_data[31:16];
          end
          default: ;
        endcase
      end
    end
  end

  //---------------------------------------------------------------- ядро ---
  logic               st_burst, st_synced, st_pkt_active, st_preamble, st_inverted;
  logic               st_warmup_done, ev_burst_start;
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

  wire core_rst = !s_axi_aresetn || soft_reset;

  rtl_demod #(.LUT_FILE(LUT_FILE)) u_core (
    .clk (s_axi_aclk), .rst (core_rst),
    .s_valid (s_axis_tvalid), .s_ready (s_axis_tready), .s_data (s_axis_tdata),
    .cfg_enable, .cfg_nco_inc, .cfg_decim, .cfg_cic_shift, .cfg_burst_thr,
    .cfg_bit_inc, .cfg_sync_word, .cfg_pkt_len, .cfg_crc_poly, .cfg_crc_init,
    .cfg_crc_residue, .cfg_freq_init, .cfg_sh_fast, .cfg_sh_slow, .cfg_fast_len,
    .cfg_dev_shift,
    .st_burst, .st_synced, .st_pkt_active, .st_preamble, .st_inverted,
    .st_warmup_done, .st_pavg, .st_noise, .st_thr_on, .st_favg, .st_dev,
    .st_in_count, .st_dec_count, .ev_burst_start,
    .m_burst_len, .m_burst_peak, .m_burst_pwr,
    .res_strobe, .res_kind, .res_crc_ok, .res_bits, .res_bytes,
    .res_pkts_in_burst, .res_win_trans, .res_win_cnt, .res_win_fsum,
    .pkt_we, .pkt_waddr, .pkt_wdata
  );

  //------------------------------------------------------------ лічильники
  logic [31:0] cnt_burst, cnt_pkt, cnt_crc_ok, cnt_crc_err;

  always_ff @(posedge s_axi_aclk) begin
    if (core_rst || clr_stats) begin
      cnt_burst <= '0; cnt_pkt <= '0; cnt_crc_ok <= '0; cnt_crc_err <= '0;
    end
    else begin
      if (ev_burst_start) cnt_burst <= cnt_burst + 1'b1;
      if (res_strobe && res_kind == 2'd0) begin
        cnt_pkt <= cnt_pkt + 1'b1;
        if (res_crc_ok) cnt_crc_ok  <= cnt_crc_ok + 1'b1;
        else            cnt_crc_err <= cnt_crc_err + 1'b1;
      end
    end
  end

  //------------------------------------------------------ защіпка результату
  logic        result_valid, result_overrun;
  logic [31:0] r_flags, r_burst_len, r_burst_pwr, r_burst_peak, r_noise;
  logic [31:0] r_favg_dev, r_win, r_win_fsum, r_bytes;

  always_ff @(posedge s_axi_aclk) begin
    if (core_rst) begin
      result_valid   <= 1'b0;
      result_overrun <= 1'b0;
    end
    else begin
      if (res_strobe) begin
        if (result_valid) result_overrun <= 1'b1;
        result_valid <= 1'b1;
        r_flags <= {res_bits, res_pkts_in_burst, res_kind, (res_kind == 2'd2),
                    st_inverted, res_crc_ok, (res_kind != 2'd1), st_preamble, 1'b1};
        r_burst_len  <= m_burst_len;
        r_burst_pwr  <= m_burst_pwr;
        r_burst_peak <= m_burst_peak;
        r_noise      <= st_noise;
        r_favg_dev   <= {st_dev, st_favg};
        r_win        <= {res_win_cnt, res_win_trans};
        r_win_fsum   <= res_win_fsum;
        r_bytes      <= 32'(res_bytes);
      end
      else if (ack_result) begin
        result_valid   <= 1'b0;
        result_overrun <= 1'b0;
      end
    end
  end

  assign irq = result_valid;

  //-------------------------------------------------------- пам'ять пакета
  // 4 банки по 64 байти (побайтні лани), щоб читати слово за один такт.
  logic [7:0] pkt_mem [0:3][0:63];

  always_ff @(posedge s_axi_aclk) begin
    if (pkt_we) pkt_mem[pkt_waddr[1:0]][pkt_waddr[7:2]] <= pkt_wdata;
  end

  wire [5:0]  pkt_rd_idx  = rd_addr[7:2];
  wire [31:0] pkt_rd_word = {pkt_mem[3][pkt_rd_idx], pkt_mem[2][pkt_rd_idx],
                             pkt_mem[1][pkt_rd_idx], pkt_mem[0][pkt_rd_idx]};

  //------------------------------------------------------------- читання ---
  always_comb begin
    if (rd_addr[8]) begin
      rd_data = pkt_rd_word;
    end
    else begin
      case (rd_addr[7:0])
        8'h00: rd_data = {31'd0, cfg_enable};
        8'h04: rd_data = {22'd0, st_inverted, st_preamble, 1'b0, cfg_enable,
                          st_warmup_done, result_overrun, result_valid,
                          st_pkt_active, st_synced, st_burst};
        8'h08: rd_data = cfg_nco_inc;
        8'h0C: rd_data = {19'd0, cfg_cic_shift, cfg_decim};
        8'h10: rd_data = cfg_burst_thr;
        8'h14: rd_data = 32'(cfg_bit_inc);
        8'h18: rd_data = 32'(cfg_sync_word);
        8'h1C: rd_data = 32'(cfg_pkt_len);
        8'h20: rd_data = {cfg_crc_init, cfg_crc_poly};
        8'h24: rd_data = 32'(cfg_crc_residue);
        8'h28: rd_data = 32'(cfg_freq_init);
        8'h2C: rd_data = {cfg_fast_len, 4'd0, cfg_dev_shift, cfg_sh_slow, cfg_sh_fast};
        8'h30: rd_data = st_noise;
        8'h34: rd_data = st_pavg;
        8'h38: rd_data = st_thr_on;
        8'h3C: rd_data = st_in_count;
        8'h40: rd_data = st_dec_count;
        8'h44: rd_data = {st_dev, st_favg};
        8'h48: rd_data = cnt_burst;
        8'h4C: rd_data = cnt_pkt;
        8'h50: rd_data = cnt_crc_ok;
        8'h54: rd_data = cnt_crc_err;
        8'h60: rd_data = r_flags;
        8'h64: rd_data = r_burst_len;
        8'h68: rd_data = r_burst_pwr;
        8'h6C: rd_data = r_burst_peak;
        8'h70: rd_data = r_noise;
        8'h74: rd_data = r_favg_dev;
        8'h78: rd_data = r_win;
        8'h7C: rd_data = r_win_fsum;
        8'h80: rd_data = r_bytes;
        8'hFC: rd_data = ID_VALUE;
        default: rd_data = '0;
      endcase
    end
  end

endmodule
