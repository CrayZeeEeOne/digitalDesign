//==============================================================================
// dsp_regs -- увесь DSP у залізі за одним AXI4-Lite (16 КБ адрес):
//
//   S_AXIS (replay з SD через iq_stream) --+
//                                          +--> rtl_demod  (демодуляція, пакети)
//   iq_gen (тестові GFSK-пакети) ----------+--> dsp_spectrum (FFT, waterfall)
//                                          +--> dsp_capture  (колонки I/Q, біти)
//
// Відлік потоку приймається, коли демодулятор увімкнений (CTRL.enable) і FFT
// має вільний банк -- один і той самий відлік бачать усі три блоки.
//
// Мапа (байтові адреси):
//   0x0000..0x01FF  демодулятор -- мапа rtl_demod_regs (ID 0x4453_4D01)
//
//   0x0200 SRC_CTRL    [0] джерело: 0 = S_AXIS, 1 = генератор  [1] генератор увімкнено
//   0x0204 GEN_RATE    2^32 * Fs / f_aclk (4.5 МВід/с при 100 МГц = 193273528)
//   0x0208 GEN_FOFS    зсув несучої, 2^32 = Fs, знаковий (-1087 кГц)
//   0x020C GEN_DEV     девіація, 2^32 = Fs (25 кГц)
//   0x0210 GEN_BIT_INC 2^32 * bitrate / Fs (19200)
//   0x0214 GEN_LEVEL   [15:0] амплітуда, [31:16] шум (6000, 1470 -> SNR 20 дБ)
//   0x0218 GEN_PERIOD  відліків на період пакета (156250)
//   0x021C GEN_GAP     відліків шуму перед пакетом (47500)
//   0x0220 GEN_PKTS    RO: пакетів відправлено
//   0x0224 GEN_STATUS  RO: [0] іде пакет
//   0x02FC ID          0x4453_5001 ("DSP" 01)
//
//   0x0300 CAP_CTRL    W: [0] arm (почати захоплення), [1] abort
//   0x0304 CAP_STATUS  RO: [2:0] стан (0 idle, 1 warmup, 2 wait, 3 record, 4 done)
//                      [3] done  [5:4] пакетів  [6] пакет пишеться  [7] FFT зайнятий
//                      [15:8] рядків waterfall
//   0x0308 CAP_WARMUP  відліків до запису (16384)
//   0x030C CAP_LEN     відліків запису (327680)
//   0x0310 CAP_COL     [15:0] CAP_LEN / 384, [31:16] CAP_LEN % 384
//   0x0314 CAP_MODE    [4:0] log2(блоків FFT на рядок waterfall) (5),
//                      [8] не чекати кінця пакета (для файлу з початку)
//   0x0318 CAP_POS     RO: відліків записано
//   0x031C CAP_T0      RO: номер вхідного відліку на початку запису
//   0x0320 + 16*p      RO, пакет p = 0, 1: START, END, FIRST_BIT, NBITS
//
//   0x0400..0x047F     біти пакетів: 0x400 пакет 0, 0x440 пакет 1; байт k у
//                      слові k/4, біти [8*(k%4)+:8]; перший біт -- MSB байта 0
//   0x0800..0x0DFF     384 колонки: [7:0] i_lo [15:8] i_hi [23:16] q_lo [31:24] q_hi (int8)
//   0x2000..0x33FF     waterfall, 40 рядків x 128 байт (рядок 0 -- початок запису,
//                      бін 0 = нижня частота); max hold софт рахує з рядків
//==============================================================================
module dsp_regs #(
  parameter int          C_S_AXI_ADDR_WIDTH = 14,
  parameter logic [31:0] ID_VALUE           = 32'h4453_5001
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

  localparam int AW = C_S_AXI_ADDR_WIDTH;

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
  logic        src_sel, gen_en;
  logic [31:0] gen_rate, gen_fofs, gen_dev, gen_bit_inc, gen_period, gen_gap;
  logic [15:0] gen_amp, gen_noise;
  logic        cap_arm, cap_abort, cap_nowait;
  logic [31:0] cap_warmup, cap_len;
  logic [15:0] cap_col_q, cap_col_r;
  logic [4:0]  cap_wf_shift;

  always_ff @(posedge s_axi_aclk) begin
    if (rst) begin
      src_sel      <= 1'b1;
      gen_en       <= 1'b0;
      gen_rate     <= 32'd193273528;
      gen_fofs     <= 32'hC229_6A45;
      gen_dev      <= 32'd23860929;
      gen_bit_inc  <= 32'd18325194;
      gen_amp      <= 16'd6000;
      gen_noise    <= 16'd1470;
      gen_period   <= 32'd156250;
      gen_gap      <= 32'd47500;
      cap_arm      <= 1'b0;
      cap_abort    <= 1'b0;
      cap_warmup   <= 32'd16384;
      cap_len      <= 32'd327680;
      cap_col_q    <= 16'd853;
      cap_col_r    <= 16'd128;
      cap_wf_shift <= 5'd5;
      cap_nowait   <= 1'b0;
    end
    else begin
      cap_arm   <= 1'b0;
      cap_abort <= 1'b0;
      if (wr_ctl) begin
        case (wr_addr[9:0])
          10'h200: begin src_sel <= wr_data[0]; gen_en <= wr_data[1]; end
          10'h204: gen_rate    <= wr_data;
          10'h208: gen_fofs    <= wr_data;
          10'h20C: gen_dev     <= wr_data;
          10'h210: gen_bit_inc <= wr_data;
          10'h214: begin gen_amp <= wr_data[15:0]; gen_noise <= wr_data[31:16]; end
          10'h218: gen_period  <= wr_data;
          10'h21C: gen_gap     <= wr_data;
          10'h300: begin cap_arm <= wr_data[0]; cap_abort <= wr_data[1]; end
          10'h308: cap_warmup  <= wr_data;
          10'h30C: cap_len     <= wr_data;
          10'h310: begin cap_col_q <= wr_data[15:0]; cap_col_r <= wr_data[31:16]; end
          10'h314: begin cap_wf_shift <= wr_data[4:0]; cap_nowait <= wr_data[8]; end
          default: ;
        endcase
      end
    end
  end

  //------------------------------------------------------------- джерело --
  logic        gen_valid, gen_ready;
  logic [31:0] gen_data, gen_pkts;
  logic        gen_burst;

  iq_gen u_gen (
    .clk (s_axi_aclk), .rst (rst),
    .cfg_enable  (gen_en),
    .cfg_rate    (gen_rate),
    .cfg_fofs    (gen_fofs),
    .cfg_dev     (gen_dev),
    .cfg_bit_inc (gen_bit_inc),
    .cfg_amp     (gen_amp),
    .cfg_noise   (gen_noise),
    .cfg_period  (gen_period),
    .cfg_gap     (gen_gap),
    .out_valid   (gen_valid),
    .out_ready   (gen_ready),
    .out_data    (gen_data),
    .st_pkts     (gen_pkts),
    .st_burst    (gen_burst)
  );

  wire        src_valid = src_sel ? gen_valid : s_axis_tvalid;
  wire [31:0] src_data  = src_sel ? gen_data  : s_axis_tdata;
  logic       spec_ready, demod_en;
  wire        sink_ready = spec_ready && demod_en;
  wire        fire       = src_valid && sink_ready;

  assign gen_ready     =  src_sel && sink_ready;
  assign s_axis_tready = !src_sel && sink_ready;

  //--------------------------------------------------------- демодулятор --
  logic [31:0] demod_rd;
  logic        tap_v, tap_burst, tap_start, tap_end, tap_bit_v, tap_bit;
  logic        demod_tready;

  rtl_demod_bank u_demod (
    .s_axi_aclk, .s_axi_aresetn,
    .wr_en (wr_demod), .wr_addr (wr_addr[8:0]), .wr_data, .wr_strb,
    .rd_addr (rd_addr[8:0]), .rd_data (demod_rd),
    .s_axis_tvalid (src_valid && spec_ready), .s_axis_tready (demod_tready),
    .s_axis_tdata  (src_data),
    .irq,
    .tap_v, .tap_burst, .tap_start, .tap_end, .tap_bit_v, .tap_bit,
    .st_enable (demod_en)
  );

  //---------------------------------------------------------- захоплення --
  logic        cap_rec, cap_in_pkt;
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
    .in_fire (fire), .in_i (src_data[15:0]), .in_q (src_data[31:16]),
    .tap_v, .tap_start, .tap_end, .tap_bit_v, .tap_bit,
    .rec (cap_rec),
    .st_state (cap_state), .st_pos (cap_pos), .st_t0 (cap_t0),
    .st_npkt (cap_npkt), .st_in_pkt (cap_in_pkt),
    .pkt_start, .pkt_end, .pkt_first, .pkt_nbits,
    .rd_en (rd_req), .rd_raw_addr (rd_req_addr[10:2]),
    .rd_bits_addr (rd_req_addr[6:2]),
    .rd_raw_data (raw_rd), .rd_bits_data (bits_rd)
  );

  //-------------------------------------------------------------- спектр --
  logic [7:0]  wf_rows;
  logic        spec_busy;
  logic [31:0] wf_rd;

  dsp_spectrum u_spec (
    .clk (s_axi_aclk), .rst (rst),
    .arm (cap_arm),
    .cfg_wf_shift (cap_wf_shift),
    .in_valid (fire), .in_rec (cap_rec),
    .in_i (src_data[15:0]), .in_q (src_data[31:16]),
    .in_ready (spec_ready),
    .st_rows (wf_rows), .st_busy (spec_busy),
    .rd_en (rd_req),
    .rd_wf_addr (rd_req_addr[12:2]),
    .rd_wf_data (wf_rd)
  );

  //------------------------------------------------------------- читання --
  logic [31:0] ctl_rd;

  always_comb begin
    ctl_rd = '0;
    case (rd_addr[9:0])
      10'h200: ctl_rd = {30'd0, gen_en, src_sel};
      10'h204: ctl_rd = gen_rate;
      10'h208: ctl_rd = gen_fofs;
      10'h20C: ctl_rd = gen_dev;
      10'h210: ctl_rd = gen_bit_inc;
      10'h214: ctl_rd = {gen_noise, gen_amp};
      10'h218: ctl_rd = gen_period;
      10'h21C: ctl_rd = gen_gap;
      10'h220: ctl_rd = gen_pkts;
      10'h224: ctl_rd = {31'd0, gen_burst};
      10'h2FC: ctl_rd = ID_VALUE;
      10'h304: ctl_rd = {16'd0, wf_rows, spec_busy, cap_in_pkt, cap_npkt,
                         (cap_state == 3'd4), cap_state};
      10'h308: ctl_rd = cap_warmup;
      10'h30C: ctl_rd = cap_len;
      10'h310: ctl_rd = {cap_col_r, cap_col_q};
      10'h314: ctl_rd = {23'd0, cap_nowait, 3'd0, cap_wf_shift};
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
      default: ;
    endcase
  end

  always_comb begin
    if      (rd_addr[AW-1:9] == '0)                    rd_data = demod_rd;     // 0x0000
    else if (rd_addr[AW-1:10] == '0)                   rd_data = ctl_rd;       // 0x0200
    else if (rd_addr[AW-1:7] == 7'h08)                 rd_data = bits_rd;      // 0x0400
    else if (rd_addr[AW-1:11] == 3'b001)               rd_data = raw_rd;       // 0x0800
    else if (rd_addr[AW-1:13] == 1'b1)                 rd_data = wf_rd;        // 0x2000
    else                                               rd_data = '0;
  end

  // demod_tready = demod_en: окремо не потрібен
  wire unused_ok = &{1'b0, demod_tready, tap_burst};

endmodule
