//==============================================================================
// dsp_regs -- увесь DSP у залізі за одним AXI4-Lite (64 КБ адрес).
//
// Вхід -- I/Q-запис із SD (через iq_stream, S_AXIS). Пакети стрибають по 15
// каналах (865.3..869.5 МГц при LO 867.4), демодулятор один, тому:
//
//   S_AXIS -> x 2^IN_SHIFT -+-> dsp_spectrum (FFT кожного блоку) -> waterfall
//                           |        `-> потужність 15 каналів -> dsp_hop -> NCO демодулятора
//                           `-> лінія затримки DL_LEN -+-> rtl_demod (пакети, CRC)
//                                                      `-> dsp_capture (колонки, біти)
//
// FFT бачить пакет на DL_LEN відліків раніше, ніж демодулятор: dsp_hop встигає
// перестроїти NCO на канал пакета і запустити захоплення. Відлік приймається,
// коли демодулятор увімкнений (CTRL.enable) і FFT має вільний банк.
//
// Мапа (байтові адреси):
//   0x0000..0x01FF  демодулятор -- мапа rtl_demod_bank (ID 0x4453_4D01)
//
//   0x0200 DSP_CTRL    [3:0] IN_SHIFT: вхід x 2^n з насиченням (запис -- +-104 LSB,
//                      6 -> +-6656); [8] W, імпульс: спорожнити лінію затримки
//                      (новий файл / перемотування)
//   0x0204 DL_LEN      RO: довжина лінії затримки, відліків
//   0x0208 IN_COUNT    RO: відліків прийнято
//   0x02FC ID          0x4453_5002 ("DSP" 02)
//
//   0x0300 CAP_CTRL    W: [0] arm (почати захоплення), [1] abort
//   0x0304 CAP_STATUS  RO: [2:0] стан (0 idle, 1 warmup, 2 wait, 3 record, 4 done)
//                      [3] done  [5:4] пакетів  [6] пакет пишеться  [7] FFT зайнятий
//                      [15:8] рядків waterfall
//   0x0308 CAP_WARMUP  відліків до запису
//   0x030C CAP_LEN     відліків запису (98304)
//   0x0310 CAP_COL     [15:0] CAP_LEN / 384, [31:16] CAP_LEN % 384
//   0x0314 CAP_MODE    [4:0] log2(блоків FFT на рядок waterfall),
//                      [8] не чекати (запис одразу після warmup),
//                      [9] чекати пакета від dsp_hop (інакше -- кінця пакета)
//   0x0318 CAP_POS     RO: відліків записано
//   0x031C CAP_T0      RO: номер відліку (затриманого потоку) на початку запису
//   0x0320 + 16*p      RO, пакет p = 0, 1: START, END, FIRST_BIT, NBITS
//
//   0x0340 SPEC_CTRL   [0] live: спектр усього потоку, рядки по колу (інакше --
//                      лише блоки захоплення, рядки 0..39 від arm)
//                      [1] заморозити кільце: рядки рахуються і йдуть у буфер
//                      останнього рядка (0x0480), але кільце не перезаписується
//   0x0344 SPEC_ROWS   RO: рядків записано (live: усього; рядок N -- у кільці на N % 256)
//   0x0348 SPEC_BIN0   [7:0] перший з 256 бінів виходу (128 = від -Fs/2)
//
//   0x0380 HOP_CTRL    [0] увімкнено, [7:4] поріг (шум << n), [11:8] IIR шуму,
//                      [15:12] блоків поспіль, [31:16] відліків чекати burst
//   0x0384 HOP_STATUS  RO: [3:0] поточний канал, [5:4] стан (0 idle, 1 wait, 2 busy),
//                      [11:8] канал останнього результату демодулятора
//   0x0388 HOP_DETS    RO: [15:0] виявлень, [31:16] з них без пакета в демодуляторі
//   0x038C HOP_CHMAP   W: [7:0] бін FFT, [11:8] канал 0..14 (15 = жоден)
//   0x0390 + 4*c       HOP_NCO[c], c = 0..14: NCO_INC демодулятора для каналу c
//   0x03CC HOP_MIN     [15:0] мінімальний поріг суми рівнів каналу (256)
//
//   0x0480..0x04FF     останній рядок спектра (128 байт, як рядок кільця)
//   0x0400..0x047F     біти пакетів: 0x400 пакет 0, 0x440 пакет 1; байт k у
//                      слові k/4, біти [8*(k%4)+:8]; перший біт -- MSB байта 0
//   0x0800..0x0DFF     384 колонки: [7:0] i_lo [15:8] i_hi [23:16] q_lo [31:24] q_hi (int8)
//   0x8000..0xFFFF     waterfall, кільце 256 рядків x 128 байт: рядок r -- слова
//                      0x8000 + 128*r ... (точка j = max бінів 2j, 2j+1 від BIN0:
//                      уся смуга, нижня частота -- зліва). Max hold рахує софт.
//==============================================================================
module dsp_regs #(
  parameter int          C_S_AXI_ADDR_WIDTH = 16,
  parameter logic [31:0] ID_VALUE           = 32'h4453_5002,
  parameter int          DL_LEN             = 4096      // степінь двійки
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

  output logic                          irq              // результат демодулятора
);

  localparam int AW  = C_S_AXI_ADDR_WIDTH;
  localparam int DLW = $clog2(DL_LEN);

  //------------------------------------------------------------ міст AXI ---
  logic          wr_en, rd_en, rd_req;
  logic [AW-1:0] wr_addr, rd_addr, rd_req_addr;
  logic [31:0]   wr_data, rd_data;
  logic [3:0]    wr_strb;

  axi_lite_regs #(.ADDR_WIDTH(AW)) u_axi (
    .s_axi_aclk, .s_axi_aresetn,
    .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,
    .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
    .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
    .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,
    .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .wr_en, .wr_addr, .wr_data, .wr_strb, .rd_en, .rd_addr, .rd_data,
    .rd_req, .rd_req_addr
  );

  wire rst = !s_axi_aresetn;

  wire wr_demod = wr_en && wr_addr[AW-1:9] == '0;
  wire wr_ctl   = wr_en && wr_addr[AW-1:10] == '0 && wr_addr[9];

  //---------------------------------------------------- регістри керування
  logic [3:0]  in_shift;
  logic        dl_clear;
  logic        cap_arm, cap_abort, cap_nowait, cap_trig_hop;
  logic [31:0] cap_warmup, cap_len;
  logic [15:0] cap_col_q, cap_col_r;
  logic [4:0]  cap_wf_shift;
  logic        spec_live, spec_freeze;
  logic [7:0]  spec_bin0;
  logic        hop_en;
  logic [3:0]  hop_thr_sh, hop_noise_sh, hop_confirm;
  logic [15:0] hop_hold, hop_thr_min;
  logic [31:0] hop_nco [0:14];
  logic        chmap_we;
  logic [7:0]  chmap_addr;
  logic [3:0]  chmap_data;

  wire  [9:0]  wa_nco = wr_addr[9:0] - 10'h390;

  always_ff @(posedge s_axi_aclk) begin
    if (rst) begin
      in_shift     <= 4'd6;
      dl_clear     <= 1'b0;
      cap_arm      <= 1'b0;
      cap_abort    <= 1'b0;
      cap_warmup   <= 32'd1;
      cap_len      <= 32'd98304;
      cap_col_q    <= 16'd256;
      cap_col_r    <= 16'd0;
      cap_wf_shift <= 5'd6;
      cap_nowait   <= 1'b0;
      cap_trig_hop <= 1'b1;
      spec_live    <= 1'b0;
      spec_freeze  <= 1'b0;
      spec_bin0    <= 8'd128;
      hop_en       <= 1'b0;
      hop_thr_sh   <= 4'd5;
      hop_noise_sh <= 4'd4;
      hop_confirm  <= 4'd2;
      hop_hold     <= 16'd8192;
      hop_thr_min  <= 16'd256;
      chmap_we     <= 1'b0;
      chmap_addr   <= '0;
      chmap_data   <= '0;
      for (int c = 0; c < 15; c++) hop_nco[c] <= '0;
    end
    else begin
      dl_clear  <= 1'b0;
      cap_arm   <= 1'b0;
      cap_abort <= 1'b0;
      chmap_we  <= 1'b0;
      if (wr_ctl) begin
        case (wr_addr[9:0])
          10'h200: begin in_shift <= wr_data[3:0]; dl_clear <= wr_data[8]; end
          10'h300: begin cap_arm <= wr_data[0]; cap_abort <= wr_data[1]; end
          10'h308: cap_warmup  <= wr_data;
          10'h30C: cap_len     <= wr_data;
          10'h310: begin cap_col_q <= wr_data[15:0]; cap_col_r <= wr_data[31:16]; end
          10'h314: begin
            cap_wf_shift <= wr_data[4:0];
            cap_nowait   <= wr_data[8];
            cap_trig_hop <= wr_data[9];
          end
          10'h340: begin spec_live <= wr_data[0]; spec_freeze <= wr_data[1]; end
          10'h348: spec_bin0 <= wr_data[7:0];
          10'h380: begin
            hop_en       <= wr_data[0];
            hop_thr_sh   <= wr_data[7:4];
            hop_noise_sh <= wr_data[11:8];
            hop_confirm  <= wr_data[15:12];
            hop_hold     <= wr_data[31:16];
          end
          10'h3CC: hop_thr_min <= wr_data[15:0];
          10'h38C: begin chmap_we <= 1'b1; chmap_addr <= wr_data[7:0]; chmap_data <= wr_data[11:8]; end
          default:
            if (wr_addr[9:0] >= 10'h390 && wr_addr[9:0] <= 10'h3C8) hop_nco[wa_nco[5:2]] <= wr_data;
        endcase
      end
    end
  end

  //------------------------------------------------- вхід і підсилення ---
  function automatic logic signed [15:0] gain(input logic signed [15:0] x, input logic [3:0] sh);
    logic signed [31:0] v;
    v = 32'(x) <<< sh;
    if (v > 32767)       return 16'sd32767;
    else if (v < -32768) return -16'sd32768;
    else                 return 16'(v);
  endfunction

  logic        spec_ready, demod_en;
  wire         sink_ready = spec_ready && demod_en;
  wire         fire       = s_axis_tvalid && sink_ready;
  wire  [15:0] g_i = gain(s_axis_tdata[15:0],  in_shift);
  wire  [15:0] g_q = gain(s_axis_tdata[31:16], in_shift);
  logic [31:0] in_count;

  assign s_axis_tready = sink_ready;

  always_ff @(posedge s_axi_aclk) begin
    if (rst) in_count <= '0;
    else if (fire) in_count <= in_count + 1'b1;
  end

  //----------------------------------------------------- лінія затримки ---
  // Відлік, прийнятий DL_LEN відліків тому, виходить разом із прийомом
  // нового. Поки лінія не заповнена, назовні нічого не йде.
  logic [31:0]    dl_mem [0:DL_LEN-1];
  logic [DLW-1:0] dl_wp;
  logic           dl_full;
  logic           dl_v;
  logic [31:0]    dl_q;

  always_ff @(posedge s_axi_aclk) begin
    if (fire) begin
      dl_mem[dl_wp] <= {g_q, g_i};
      dl_q          <= dl_mem[dl_wp];
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (rst || dl_clear) begin
      dl_wp   <= '0;
      dl_full <= 1'b0;
      dl_v    <= 1'b0;
    end
    else begin
      dl_v <= fire && dl_full;
      if (fire) begin
        dl_wp <= dl_wp + 1'b1;
        if (dl_wp == DLW'(DL_LEN - 1)) dl_full <= 1'b1;
      end
    end
  end

  //--------------------------------------------------------- демодулятор --
  logic [31:0] demod_rd;
  logic        tap_v, tap_burst, tap_start, tap_end, tap_bit_v, tap_bit;
  logic        demod_tready;
  logic        hop_nco_en;
  logic [31:0] hop_nco_inc;

  rtl_demod_bank u_demod (
    .s_axi_aclk, .s_axi_aresetn,
    .wr_en (wr_demod), .wr_addr (wr_addr[8:0]), .wr_data, .wr_strb,
    .rd_addr (rd_addr[8:0]), .rd_data (demod_rd),
    .s_axis_tvalid (dl_v), .s_axis_tready (demod_tready),
    .s_axis_tdata  (dl_q),
    .irq,
    .nco_ovr_en (hop_nco_en), .nco_ovr_inc (hop_nco_inc),
    .tap_v, .tap_burst, .tap_start, .tap_end, .tap_bit_v, .tap_bit,
    .st_enable (demod_en)
  );

  //-------------------------------------------------------------- спектр --
  logic [31:0] wf_rows;
  logic        spec_busy;
  logic [31:0] wf_rd, last_rd;
  logic [23:0] ch_pow [0:14];
  logic        ch_done;
  logic        cap_rec;

  // Спектр бачить потік до затримки (для dsp_hop). in_rec захоплення -- із
  // затриманого потоку, тож режим "лише блоки захоплення" (SPEC_CTRL = 0)
  // зміщений на DL_LEN відліків; прошивка працює в live.
  dsp_spectrum u_spec (
    .clk (s_axi_aclk), .rst (rst),
    .arm (cap_arm && !spec_live),             // live: захоплення не чіпає спектр
    .cfg_live (spec_live),
    .cfg_bin0 (spec_bin0),
    .cfg_wf_shift (cap_wf_shift),
    .cfg_freeze (spec_freeze),
    .in_valid (fire), .in_rec (cap_rec),
    .in_i (g_i), .in_q (g_q),
    .in_ready (spec_ready),
    .st_rows (wf_rows), .st_busy (spec_busy),
    .chmap_we, .chmap_addr, .chmap_data,
    .ch_pow, .ch_done,
    .rd_en (rd_req),
    .rd_wf_addr (rd_req_addr[14:2]),
    .rd_wf_data (wf_rd),
    .rd_last_addr (rd_addr[6:2]),
    .rd_last_data (last_rd)
  );

  //------------------------------------------------------------- канали --
  logic [3:0]  hop_ch, hop_res_ch;
  logic        hop_trig;
  logic [1:0]  hop_state;
  logic [15:0] hop_dets, hop_lost;
  logic        irq_q;

  dsp_hop u_hop (
    .clk (s_axi_aclk), .rst (rst),
    .cfg_en (hop_en), .cfg_thr_sh (hop_thr_sh), .cfg_noise_sh (hop_noise_sh),
    .cfg_confirm (hop_confirm), .cfg_thr_min (hop_thr_min), .cfg_hold (hop_hold), .cfg_nco (hop_nco),
    .ch_pow, .ch_done,
    .in_fire (fire),
    .demod_burst (tap_burst),
    .nco_en (hop_nco_en), .nco_inc (hop_nco_inc),
    .cur_ch (hop_ch), .trig (hop_trig),
    .st_state (hop_state), .st_dets (hop_dets), .st_lost (hop_lost)
  );

  // канал, на якому демодулятор дав останній результат
  always_ff @(posedge s_axi_aclk) begin
    irq_q <= irq;
    if (rst) hop_res_ch <= '0;
    else if (irq && !irq_q) hop_res_ch <= hop_ch;
  end

  //---------------------------------------------------------- захоплення --
  logic        cap_in_pkt;
  logic [2:0]  cap_state;
  logic [31:0] cap_pos, cap_t0;
  logic [1:0]  cap_npkt;
  logic [31:0] pkt_start [0:1], pkt_end [0:1], pkt_first [0:1];
  logic [9:0]  pkt_nbits [0:1];
  logic [31:0] raw_rd, bits_rd;

  dsp_capture u_cap (
    .clk (s_axi_aclk), .rst (rst),
    .arm (cap_arm), .abort (cap_abort),
    .cfg_warmup (cap_warmup), .cfg_len (cap_len),
    .cfg_col_q (cap_col_q), .cfg_col_r (cap_col_r),
    .cfg_nowait (cap_nowait),
    .cfg_trig (cap_trig_hop), .trig (hop_trig),
    .in_fire (dl_v), .in_i (dl_q[15:0]), .in_q (dl_q[31:16]),
    .tap_v, .tap_start, .tap_end, .tap_bit_v, .tap_bit,
    .rec (cap_rec),
    .st_state (cap_state), .st_pos (cap_pos), .st_t0 (cap_t0),
    .st_npkt (cap_npkt), .st_in_pkt (cap_in_pkt),
    .pkt_start, .pkt_end, .pkt_first, .pkt_nbits,
    .rd_en (rd_req), .rd_raw_addr (rd_req_addr[10:2]),
    .rd_bits_addr (rd_req_addr[6:2]),
    .rd_raw_data (raw_rd), .rd_bits_data (bits_rd)
  );

  //------------------------------------------------------------- читання --
  logic [31:0] ctl_rd;
  wire  [9:0]  ra_nco = rd_addr[9:0] - 10'h390;

  always_comb begin
    ctl_rd = '0;
    case (rd_addr[9:0])
      10'h200: ctl_rd = 32'(in_shift);
      10'h204: ctl_rd = 32'(DL_LEN);
      10'h208: ctl_rd = in_count;
      10'h2FC: ctl_rd = ID_VALUE;
      10'h304: ctl_rd = {16'd0, (wf_rows > 32'd255) ? 8'd255 : wf_rows[7:0], spec_busy, cap_in_pkt, cap_npkt,
                         (cap_state == 3'd4), cap_state};
      10'h308: ctl_rd = cap_warmup;
      10'h30C: ctl_rd = cap_len;
      10'h310: ctl_rd = {cap_col_r, cap_col_q};
      10'h314: ctl_rd = {22'd0, cap_trig_hop, cap_nowait, 3'd0, cap_wf_shift};
      10'h318: ctl_rd = cap_pos;
      10'h31C: ctl_rd = cap_t0;
      10'h320: ctl_rd = pkt_start[0];
      10'h324: ctl_rd = pkt_end[0];
      10'h328: ctl_rd = pkt_first[0];
      10'h32C: ctl_rd = 32'(pkt_nbits[0]);
      10'h330: ctl_rd = pkt_start[1];
      10'h334: ctl_rd = pkt_end[1];
      10'h338: ctl_rd = pkt_first[1];
      10'h33C: ctl_rd = 32'(pkt_nbits[1]);
      10'h340: ctl_rd = {30'd0, spec_freeze, spec_live};
      10'h344: ctl_rd = wf_rows;
      10'h348: ctl_rd = 32'(spec_bin0);
      10'h380: ctl_rd = {hop_hold, hop_confirm, hop_noise_sh, hop_thr_sh, 3'd0, hop_en};
      10'h384: ctl_rd = {20'd0, hop_res_ch, 2'd0, hop_state, hop_ch};
      10'h388: ctl_rd = {hop_lost, hop_dets};
      10'h3CC: ctl_rd = 32'(hop_thr_min);
      default:
        if (rd_addr[9:0] >= 10'h390 && rd_addr[9:0] <= 10'h3C8) ctl_rd = hop_nco[ra_nco[5:2]];
    endcase
  end

  always_comb begin
    if      (rd_addr[AW-1:9] == '0)                    rd_data = demod_rd;     // 0x0000
    else if (rd_addr[AW-1:10] == '0)                   rd_data = ctl_rd;       // 0x0200
    else if (rd_addr[AW-1:7] == 7'h08)                 rd_data = bits_rd;      // 0x0400
    else if (rd_addr[AW-1:7] == 7'h09)                 rd_data = last_rd;      // 0x0480
    else if (rd_addr[AW-1:11] == 3'b001)               rd_data = raw_rd;       // 0x0800
    else if (rd_addr[AW-1])                            rd_data = wf_rd;        // 0x8000
    else                                               rd_data = '0;
  end

  // demod_tready = demod_en: окремо не потрібен
  wire unused_ok = &{1'b0, demod_tready, tap_burst};

endmodule
