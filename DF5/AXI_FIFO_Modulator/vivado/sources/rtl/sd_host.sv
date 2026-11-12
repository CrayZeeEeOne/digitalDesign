//==============================================================================
// sd_host -- microSD у нативному режимі (SD bus, 4 біти даних) і потік I/Q з
// картки прямо в DSP, без процесора на кожному байті.
//
//   MicroBlaze --AXI4-Lite--> команди (CMD + ARG -> відповідь), блок 512 байт
//                             через буфер (читання / запис, для FatFs)
//   потік: STREAM_LBA, STREAM_CNT -> CMD18 -> блоки -> FIFO 16 КБ -> розпакування
//          (int8 або int16 I/Q) -> темп RATE (4.5 МВід/с) -> M_AXIS -> dsp_top
//
// Шина SD (Physical Layer Simplified Spec, гл. 4):
//   CLK   генерується тут: напівперіод = (CLK_DIV + 1) тактів aclk (1 -> 25 МГц,
//         124 -> 400 кГц для ідентифікації). Тактова йде лише поки є робота
//         (і ще 8 тактів після), або постійно з CTRL.clk_free (74 такти при старті).
//   CMD   команда 48 біт (старт 0, 1, індекс, аргумент, CRC7, стоп 1), відповідь
//         48 або 136 біт; хост міняє вихід по спаду CLK, картка читає по фронту.
//   DAT   блок: старт 0 на всіх 4 лініях, 1024 тетради (старша тетрада байта
//         першою, DAT3 -- старший біт), CRC16 кожної лінії, стоп 1.
//   Вхід CMD/DAT читається через SDLY тактів aclk після фронту CLK (тут лінії
//   стабільні: картка міняє їх по спаду з затримкою до 14 нс).
//
// Потік читає STREAM_CNT блоків одним CMD18 і закінчує CMD12. Якщо у FIFO немає
// місця на наступний блок, CLK зупиняється між блоками (картка чекає) -- дані не
// губляться. На виході відлік іде раз на тік лічильника RATE (2^32 * Fs / f_aclk);
// RATE = 0 -- без темпу. Тік без готового відліку рахується в UNDERRUN.
//
// Мапа (байтові адреси, 4 КБ):
//   0x000 CTRL        [7:0] CLK_DIV  [11:8] SDLY  [12] clk_free  [16] FMT8 (файл int8)
//   0x004 STATUS  RO  [0] команда йде  [1] дані йдуть  [2] потік іде
//                     [4] тайм-аут відповіді  [5] CRC відповіді  [6] тайм-аут даних
//                     [7] CRC даних  [8] запис: картка не прийняла (CRC status)
//                     (помилки скидаються наступною командою / потоком)
//                     [16] лінія CMD, [20:17] лінії DAT3..DAT0 зараз (діагностика)
//   0x008 CMD_ARG
//   0x00C CMD     W   запуск: [5:0] індекс  [7:6] відповідь 0 / 1 = 48 біт / 2 = 136 біт
//                     [8] чекати busy на DAT0 (R1b)  [9] перевіряти CRC7 відповіді
//                     [11:10] дані: 0 немає, 1 читати блок у буфер, 2 писати блок з буфера
//   0x010..0x01C RESP0..3  відповідь: 48 біт -- RESP0 = біти [39:8] (32-бітний вміст);
//                     136 біт -- RESP3..RESP0 = біти [127:0] (CID / CSD як у SPI)
//   0x020 STREAM_LBA  адреса першого блоку (SDHC -- номер блоку)
//   0x024 STREAM_CNT  блоків
//   0x028 STREAM_CTRL W [0] старт  [1] стоп (CMD12)  [2] скинути FIFO і розпакування
//   0x02C STREAM_DONE RO блоків прочитано в цьому потоці
//   0x030 FIFO_LEVEL  RO слів у FIFO
//   0x034 RATE        темп виходу, 2^32 * Fs / f_aclk; 0 = без темпу
//   0x038 UNDERRUN    RO тіків без відліку (запис -- обнулити)
//   0x03C ID          0x5344_0001 ("SD" 01)
//   0x040 OUT_COUNT   RO відліків видано в M_AXIS (запис -- обнулити)
//   0x200..0x3FF      буфер блоку 512 байт, байт k у слові k/4, біти [8*(k%4)+:8]
//==============================================================================
module sd_host #(
  parameter int          C_S_AXI_ADDR_WIDTH = 12,
  parameter logic [31:0] ID_VALUE           = 32'h5344_0001,
  parameter int          FIFO_DEPTH         = 4096     // слів по 32 біти
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

  // потік відліків {Q, I}
  output logic                          m_axis_tvalid,
  input  logic                          m_axis_tready,
  output logic [31:0]                   m_axis_tdata,

  // шина SD (тристабільні буфери -- в обгортці)
  output logic                          sd_clk,
  output logic                          sd_cmd_o,
  output logic                          sd_cmd_oe,
  input  logic                          sd_cmd_i,
  output logic [3:0]                    sd_dat_o,
  output logic                          sd_dat_oe,
  input  logic [3:0]                    sd_dat_i
);

  localparam int AW = C_S_AXI_ADDR_WIDTH;
  localparam int FW = $clog2(FIFO_DEPTH);

  wire clk = s_axi_aclk;
  wire rst = !s_axi_aresetn;

  //------------------------------------------------------------ міст AXI ---
  logic          wr_en, rd_en;
  logic [AW-1:0] wr_addr, rd_addr;
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
    .rd_req (), .rd_req_addr ()
  );

  wire wr_buf = wr_en && wr_addr[AW-1:9] == (AW-9)'(1);     // 0x200..0x3FF
  wire wr_reg = wr_en && wr_addr[AW-1:9] == '0;

  //------------------------------------------------------------ регістри ---
  logic [7:0]  cfg_div;
  logic [3:0]  cfg_sdly;
  logic        cfg_free, cfg_fmt8;
  logic [31:0] cmd_arg, st_lba, st_cnt, cfg_rate;
  logic [5:0]  cmd_idx;
  logic [1:0]  cmd_rsp, cmd_data;
  logic        cmd_busy_w, cmd_crc;
  logic        cpu_go, st_go, st_stop, fifo_clr;
  logic        clr_under, clr_out;

  always_ff @(posedge clk) begin
    cpu_go    <= 1'b0;
    st_go     <= 1'b0;
    st_stop   <= 1'b0;
    fifo_clr  <= 1'b0;
    clr_under <= 1'b0;
    clr_out   <= 1'b0;
    if (rst) begin
      cfg_div  <= 8'd124;
      cfg_sdly <= 4'd2;
      cfg_free <= 1'b0;
      cfg_fmt8 <= 1'b0;
      cmd_arg  <= '0;
      st_lba   <= '0;
      st_cnt   <= '0;
      cfg_rate <= '0;
      cmd_idx  <= '0;
      cmd_rsp  <= '0;
      cmd_data <= '0;
      cmd_busy_w <= 1'b0;
      cmd_crc  <= 1'b0;
    end
    else if (wr_reg) begin
      case (wr_addr[8:0])
        9'h000: begin cfg_div <= wr_data[7:0]; cfg_sdly <= wr_data[11:8];
                      cfg_free <= wr_data[12]; cfg_fmt8 <= wr_data[16]; end
        9'h008: cmd_arg <= wr_data;
        9'h00C: begin
          cmd_idx    <= wr_data[5:0];
          cmd_rsp    <= wr_data[7:6];
          cmd_busy_w <= wr_data[8];
          cmd_crc    <= wr_data[9];
          cmd_data   <= wr_data[11:10];
          cpu_go     <= 1'b1;
        end
        9'h020: st_lba <= wr_data;
        9'h024: st_cnt <= wr_data;
        9'h028: begin st_go <= wr_data[0]; st_stop <= wr_data[1]; fifo_clr <= wr_data[2]; end
        9'h034: cfg_rate <= wr_data;
        9'h038: clr_under <= 1'b1;
        9'h040: clr_out <= 1'b1;
        default: ;
      endcase
    end
  end

  //------------------------------------------------------ тактова SD -------
  // run: комусь потрібна тактова. Зупиняється лише в низькому рівні (після спаду).
  logic       run;
  logic [7:0] div_cnt;
  logic       rise, fall, smp;
  logic [3:0] ph;                              // тактів aclk від фронту CLK
  logic       ph_on;

  wire tick_div = (div_cnt == cfg_div);
  assign rise = tick_div && !sd_clk && run;
  assign fall = tick_div && sd_clk;

  always_ff @(posedge clk) begin
    if (rst) begin
      sd_clk  <= 1'b0;
      div_cnt <= '0;
    end
    else if (!sd_clk && !run) div_cnt <= '0;   // стоїмо в низькому рівні
    else if (tick_div) begin
      div_cnt <= '0;
      sd_clk  <= ~sd_clk;
    end
    else div_cnt <= div_cnt + 1'b1;
  end

  // вхідні регістри (IOB) і момент читання -- SDLY тактів після фронту
  logic       cmd_iq;
  logic [3:0] dat_iq;
  always_ff @(posedge clk) begin
    cmd_iq <= sd_cmd_i;
    dat_iq <= sd_dat_i;
    if (rst) begin
      ph    <= '0;
      ph_on <= 1'b0;
    end
    else if (rise) begin
      ph    <= '0;
      ph_on <= 1'b1;
    end
    else if (ph_on) begin
      if (ph == cfg_sdly) ph_on <= 1'b0;
      else ph <= ph + 1'b1;
    end
  end
  assign smp = ph_on && (ph == cfg_sdly);

  //---------------------------------------------------------- CRC ----------
  function automatic logic [6:0] crc7_bit(input logic [6:0] c, input logic b);
    logic fb;
    fb = c[6] ^ b;
    return {c[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
  endfunction

  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input logic b);
    logic fb;
    fb = c[15] ^ b;
    return {c[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
  endfunction

  function automatic logic [6:0] crc7_40(input logic [39:0] v);
    logic [6:0] c;
    c = '0;
    for (int i = 39; i >= 0; i--) c = crc7_bit(c, v[i]);
    return c;
  endfunction

  //------------------------------------------------------ буфер блоку ------
  logic [31:0] buf_mem [0:127];
  logic        buf_we;
  logic [6:0]  buf_waddr;
  logic [31:0] buf_wdata;
  logic [6:0]  buf_raddr;                      // для запису на картку
  wire  [31:0] buf_rword = buf_mem[buf_raddr];

  always_ff @(posedge clk) begin
    if (buf_we) buf_mem[buf_waddr] <= buf_wdata;
    else if (wr_buf) buf_mem[wr_addr[8:2]] <= wr_data;
  end

  //---------------------------------------------------------- FIFO ---------
  logic        f_we, f_full, f_valid, f_ready, f_empty;
  logic [31:0] f_wdata, f_data;
  logic [FW:0] f_level;

  iq_stream_fifo #(.WIDTH(32), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk (clk), .rst (rst || fifo_clr),
    .wr_en (f_we), .wr_data (f_wdata), .full (f_full),
    .m_valid (f_valid), .m_ready (f_ready), .m_data (f_data),
    .empty (f_empty), .level (f_level)
  );

  wire fifo_room = (f_level <= (FW+1)'(FIFO_DEPTH - 129));  // місце на блок + запас

  //------------------------------------------------------ CMD-автомат ------
  typedef enum logic [2:0] {C_IDLE, C_TX, C_RWAIT, C_RX, C_BUSY, C_TAIL} cst_t;
  cst_t        cs;
  logic [47:0] c_tx;
  logic [7:0]  c_cnt;
  logic [135:0] c_rx;
  logic [23:0] c_tmo;
  logic        c_long, c_bw, c_crc;
  logic        c_err_tmo, c_err_crc;
  logic [127:0] resp;
  logic        c_go;                           // старт від CPU або від потоку
  logic [5:0]  c_go_idx;
  logic [31:0] c_go_arg;
  logic [1:0]  c_go_rsp;
  logic        c_go_bw, c_go_crc;
  logic [3:0]  tail_n;
  logic [1:0]  cmd_rsp_now;                    // тип відповіді поточної команди
  logic        st_abort;                       // потік: стоп від CPU
  logic        d_kill;                         // зупинити автомат DAT (команда не пройшла)

  always_ff @(posedge clk) begin
    if (rst) begin
      cs        <= C_IDLE;
      sd_cmd_o  <= 1'b1;
      sd_cmd_oe <= 1'b0;
      c_err_tmo <= 1'b0;
      c_err_crc <= 1'b0;
      tail_n    <= '0;
    end
    else begin
      case (cs)
        C_IDLE: if (c_go) begin
          c_tx      <= {2'b01, c_go_idx, c_go_arg, crc7_40({2'b01, c_go_idx, c_go_arg}), 1'b1};
          c_cnt     <= 8'd48;
          c_long    <= (c_go_rsp == 2'd2);
          c_bw      <= c_go_bw;
          c_crc     <= c_go_crc && (c_go_rsp == 2'd1);
          c_err_tmo <= 1'b0;
          c_err_crc <= 1'b0;
          cs        <= C_TX;
        end
        // біт за бітом по спаду; після 48-го (стоп) -- відпустити лінію
        C_TX: if (fall) begin
          if (c_cnt != 0) begin
            sd_cmd_oe <= 1'b1;
            sd_cmd_o  <= c_tx[47];
            c_tx      <= {c_tx[46:0], 1'b1};
            c_cnt     <= c_cnt - 1'b1;
          end
          else begin
            sd_cmd_oe <= 1'b0;
            sd_cmd_o  <= 1'b1;
            c_tmo     <= '0;
            if (cmd_rsp_now != 2'd0) cs <= C_RWAIT;
            else if (c_bw) cs <= C_BUSY;
            else begin cs <= C_TAIL; tail_n <= 4'd8; end
          end
        end
        C_RWAIT: if (smp) begin
          if (!cmd_iq) begin
            c_rx  <= '0;
            c_cnt <= c_long ? 8'd135 : 8'd47;
            cs    <= C_RX;
          end
          else if (c_tmo == 24'd200) begin
            c_err_tmo <= 1'b1;
            cs <= C_TAIL; tail_n <= 4'd8;
          end
          else c_tmo <= c_tmo + 1'b1;
        end
        C_RX: if (smp) begin
          c_rx  <= {c_rx[134:0], cmd_iq};
          c_cnt <= c_cnt - 1'b1;
          if (c_cnt == 8'd1) begin
            logic [135:0] r;
            r = {c_rx[134:0], cmd_iq};
            if (c_long) resp <= r[127:0];
            else        resp <= {96'd0, r[39:8]};
            if (c_crc && crc7_40(r[47:8]) != r[7:1]) c_err_crc <= 1'b1;
            c_tmo <= '0;
            if (c_bw) cs <= C_BUSY;
            else begin cs <= C_TAIL; tail_n <= 4'd8; end
          end
        end
        // R1b: DAT0 = 0, поки картка зайнята (перші 8 тактів не дивимось: busy
        // починається не одразу)
        C_BUSY: if (smp) begin
          c_tmo <= c_tmo + 1'b1;
          if (c_tmo > 24'd8 && dat_iq[0]) begin cs <= C_TAIL; tail_n <= 4'd8; end
          else if (c_tmo == 24'hFFFFFF) begin c_err_tmo <= 1'b1; cs <= C_TAIL; tail_n <= 4'd8; end
        end
        // 8 тактів після команди (Nrc), потім тактова може стати
        C_TAIL: if (fall) begin
          if (tail_n == 0) cs <= C_IDLE;
          else tail_n <= tail_n - 1'b1;
        end
        default: cs <= C_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) if (cs == C_IDLE && c_go) cmd_rsp_now <= c_go_rsp;

  //------------------------------------------------------ DAT-автомат ------
  typedef enum logic [3:0] {D_IDLE, D_WAIT, D_DATA, D_CRC, D_END,
                            W_GAP, W_DATA, W_CRC, W_END, W_STAT, W_BUSY} dst_t;
  dst_t        ds;
  logic        d_stream;                       // блоки -> FIFO, інакше -> буфер
  logic [31:0] d_left;                         // блоків лишилось (потік)
  logic [31:0] d_done;
  logic [10:0] d_n;                            // тетрада / біт
  logic [15:0] d_crc [0:3];
  logic [15:0] d_rcrc [0:3];
  logic [3:0]  d_hi;                           // старша тетрада байта
  logic [31:0] d_word;
  logic [1:0]  d_byte;
  logic [24:0] d_tmo;
  logic        d_err_tmo, d_err_crc, d_err_wr;
  logic [2:0]  d_stat;
  logic        d_go_rd, d_go_wr;
  logic [15:0] w_crc_sh [0:3];

  // тетрада для запису: байт n/2 буфера, старша тетрада першою
  wire [10:0] w_byte = {1'b0, d_n[10:1]};
  wire [7:0]  w_b    = buf_rword[8*w_byte[1:0] +: 8];
  wire [3:0]  w_nib  = d_n[0] ? w_b[3:0] : w_b[7:4];

  assign buf_raddr = w_byte[8:2];

  always_ff @(posedge clk) begin
    buf_we <= 1'b0;
    f_we   <= 1'b0;
    if (rst) begin
      ds        <= D_IDLE;
      sd_dat_oe <= 1'b0;
      sd_dat_o  <= 4'hF;
      d_err_tmo <= 1'b0;
      d_err_crc <= 1'b0;
      d_err_wr  <= 1'b0;
      d_done    <= '0;
    end
    else if (d_kill) begin
      ds        <= D_IDLE;
      sd_dat_oe <= 1'b0;
      sd_dat_o  <= 4'hF;
    end
    else begin
      case (ds)
        D_IDLE: begin
          if (d_go_rd) begin
            d_err_tmo <= 1'b0; d_err_crc <= 1'b0; d_err_wr <= 1'b0;
            d_done    <= '0;
            d_left    <= st_cnt;
            d_tmo     <= '0;
            ds        <= D_WAIT;
          end
          else if (d_go_wr) begin
            d_err_tmo <= 1'b0; d_err_crc <= 1'b0; d_err_wr <= 1'b0;
            d_n       <= '0;
            ds        <= W_GAP;
          end
        end

        //------------------------------------------------- читання блоку
        D_WAIT: if (st_abort && d_stream) ds <= D_IDLE;
        else if (smp) begin
          if (!dat_iq[0]) begin
            d_n    <= '0;
            d_byte <= '0;
            for (int l = 0; l < 4; l++) d_crc[l] <= '0;
            ds     <= D_DATA;
          end
          else if (d_tmo == 25'h1FFFFFF) begin d_err_tmo <= 1'b1; ds <= D_IDLE; end
          else d_tmo <= d_tmo + 1'b1;
        end
        D_DATA: if (smp) begin
          for (int l = 0; l < 4; l++) d_crc[l] <= crc16_bit(d_crc[l], dat_iq[l]);
          d_n <= d_n + 1'b1;
          if (!d_n[0]) d_hi <= dat_iq;
          else begin
            logic [31:0] w;
            w = d_word;
            w[8*d_byte +: 8] = {d_hi, dat_iq};
            d_word <= w;
            d_byte <= d_byte + 1'b1;
            if (d_byte == 2'd3) begin
              if (d_stream) begin f_we <= 1'b1; f_wdata <= w; end
              else begin buf_we <= 1'b1; buf_waddr <= d_n[9:3]; buf_wdata <= w; end
            end
          end
          if (d_n == 11'd1023) begin d_n <= '0; ds <= D_CRC; end
        end
        D_CRC: if (smp) begin
          for (int l = 0; l < 4; l++) d_rcrc[l] <= {d_rcrc[l][14:0], dat_iq[l]};
          d_n <= d_n + 1'b1;
          if (d_n == 11'd15) ds <= D_END;
        end
        D_END: if (smp) begin
          for (int l = 0; l < 4; l++) if (d_rcrc[l] != d_crc[l]) d_err_crc <= 1'b1;
          d_done <= d_done + 1'b1;
          d_tmo  <= '0;
          if (d_stream && d_left > 1 && !st_abort) begin
            d_left <= d_left - 1'b1;
            ds     <= D_WAIT;
          end
          else ds <= D_IDLE;
        end

        //------------------------------------------------- запис блоку
        // Nwr = 2 такти після відповіді, далі старт 0 на всіх лініях
        W_GAP: if (fall) begin
          d_n <= d_n + 1'b1;
          if (d_n == 11'd1) begin
            sd_dat_oe <= 1'b1;
            sd_dat_o  <= 4'h0;
            d_n       <= '0;
            for (int l = 0; l < 4; l++) d_crc[l] <= '0;
            ds        <= W_DATA;
          end
        end
        W_DATA: if (fall) begin
          sd_dat_o <= w_nib;
          for (int l = 0; l < 4; l++) d_crc[l] <= crc16_bit(d_crc[l], w_nib[l]);
          d_n <= d_n + 1'b1;
          if (d_n == 11'd1023) ds <= W_CRC;
        end
        // CRC16 кожної лінії, старшим бітом першим (CRC уже порахований по всіх
        // 1024 тетрадах: останнє оновлення було на попередньому спаді)
        W_CRC: if (fall) begin
          for (int l = 0; l < 4; l++) begin
            logic [15:0] c;
            c = (d_n == 11'd1024) ? d_crc[l] : w_crc_sh[l];
            sd_dat_o[l] <= c[15];
            w_crc_sh[l] <= {c[14:0], 1'b0};
          end
          d_n <= d_n + 1'b1;
          if (d_n == 11'd1039) ds <= W_END;
        end
        // стоп-біт 1, на наступному спаді -- відпустити лінії
        W_END: if (fall) begin
          if (d_n == 11'd1040) begin
            sd_dat_o <= 4'hF;
            d_n      <= d_n + 1'b1;
          end
          else begin
            sd_dat_oe <= 1'b0;
            d_tmo     <= '0;
            d_n       <= '0;
            ds        <= W_STAT;
          end
        end
        // CRC status: старт 0, три біти (010 = прийнято), стоп
        W_STAT: if (smp) begin
          if (d_n == 0) begin
            if (!dat_iq[0]) d_n <= 11'd1;
            else if (d_tmo == 25'd1000) begin d_err_wr <= 1'b1; ds <= D_IDLE; end
            else d_tmo <= d_tmo + 1'b1;
          end
          else begin
            d_stat <= {d_stat[1:0], dat_iq[0]};
            d_n    <= d_n + 1'b1;
            if (d_n == 11'd3) begin
              if ({d_stat[1:0], dat_iq[0]} != 3'b010) d_err_wr <= 1'b1;
              d_tmo <= '0;
              ds    <= W_BUSY;
            end
          end
        end
        // програмування: DAT0 = 0, поки картка зайнята
        W_BUSY: if (smp) begin
          d_tmo <= d_tmo + 1'b1;
          if (d_tmo > 25'd8 && dat_iq[0]) ds <= D_IDLE;
          else if (d_tmo == 25'h1FFFFFF) begin d_err_tmo <= 1'b1; ds <= D_IDLE; end
        end
        default: ds <= D_IDLE;
      endcase
    end
  end

  //--------------------------------------------- керування командами/потоком
  // CPU-команда з даними: читання -- автомат DAT стартує разом із командою
  // (блок може початися ще до кінця відповіді); запис -- після відповіді.
  // Потік: CMD18 + DAT у режимі FIFO; після останнього блоку -- CMD12 (R1b).
  typedef enum logic [2:0] {K_IDLE, K_CPU, K_CPU_WR, K_ST_CMD, K_ST_DATA, K_ST_STOP, K_ST_END} kst_t;
  kst_t  ks;

  always_ff @(posedge clk) begin
    c_go    <= 1'b0;
    d_go_rd <= 1'b0;
    d_go_wr <= 1'b0;
    d_kill  <= 1'b0;
    if (rst) begin
      ks       <= K_IDLE;
      st_abort <= 1'b0;
      d_stream <= 1'b0;
    end
    else begin
      if (st_stop) st_abort <= 1'b1;
      case (ks)
        K_IDLE: begin
          st_abort <= 1'b0;
          if (cpu_go) begin
            c_go     <= 1'b1;
            c_go_idx <= cmd_idx;
            c_go_arg <= cmd_arg;
            c_go_rsp <= cmd_rsp;
            c_go_bw  <= cmd_busy_w;
            c_go_crc <= cmd_crc;
            d_stream <= 1'b0;
            if (cmd_data == 2'd1) d_go_rd <= 1'b1;
            ks <= (cmd_data == 2'd2) ? K_CPU_WR : K_CPU;
          end
          else if (st_go && st_cnt != 0) begin
            c_go     <= 1'b1;
            c_go_idx <= 6'd18;
            c_go_arg <= st_lba;
            c_go_rsp <= 2'd1;
            c_go_bw  <= 1'b0;
            c_go_crc <= 1'b1;
            d_stream <= 1'b1;
            d_go_rd  <= 1'b1;
            ks       <= K_ST_CMD;
          end
        end
        K_CPU: if (cs == C_IDLE && !c_go) begin
          // команда не пройшла -- блоку не буде
          if ((c_err_tmo || c_err_crc) && ds != D_IDLE) d_kill <= 1'b1;
          else if (ds == D_IDLE && !d_go_rd && !d_go_wr) ks <= K_IDLE;
        end
        K_CPU_WR: if (cs == C_IDLE && !c_go) begin
          // відповідь прийнята: тепер дані (якщо команда пройшла)
          if (!c_err_tmo && !c_err_crc) begin d_go_wr <= 1'b1; ks <= K_CPU; end
          else ks <= K_IDLE;
        end
        K_ST_CMD: if (cs == C_IDLE && !c_go) begin
          if (c_err_tmo || c_err_crc) begin d_kill <= 1'b1; ks <= K_ST_STOP; end
          else ks <= K_ST_DATA;
        end
        K_ST_DATA: if (ds == D_IDLE && !d_go_rd) ks <= K_ST_STOP;
        K_ST_STOP: begin
          c_go     <= 1'b1;
          c_go_idx <= 6'd12;
          c_go_arg <= '0;
          c_go_rsp <= 2'd1;
          c_go_bw  <= 1'b1;
          c_go_crc <= 1'b0;
          ks       <= K_ST_END;
        end
        K_ST_END: if (cs == C_IDLE && !c_go) ks <= K_IDLE;
        default: ks <= K_IDLE;
      endcase
    end
  end

  // тактова: команда / дані / постійно; між блоками потоку -- лише якщо є місце
  wire hold = d_stream && (ds == D_WAIT) && !fifo_room;
  assign run = cfg_free || ((cs != C_IDLE) || (ds != D_IDLE)) && !hold;

  //------------------------------------------- розпакування і темп виходу --
  logic        u_have;                         // є слово
  logic [31:0] u_word;
  logic        u_half;                         // FMT8: друга половина слова
  logic [31:0] rate_acc;
  logic        pend;
  logic [31:0] under, out_cnt;

  wire [31:0] u_sample = !cfg_fmt8 ? u_word
                       : u_half ? {{8{u_word[31]}}, u_word[31:24], {8{u_word[23]}}, u_word[23:16]}
                                : {{8{u_word[15]}}, u_word[15:8],  {8{u_word[7]}},  u_word[7:0]};
  wire        paced    = (cfg_rate == 0) || pend;
  wire        out_hs   = m_axis_tvalid && m_axis_tready;

  assign f_ready       = !u_have || (out_hs && (!cfg_fmt8 || u_half));
  assign m_axis_tvalid = u_have && paced;
  assign m_axis_tdata  = u_sample;

  always_ff @(posedge clk) begin
    if (rst || fifo_clr) begin
      u_have   <= 1'b0;
      u_half   <= 1'b0;
      rate_acc <= '0;
      pend     <= 1'b0;
    end
    else begin
      logic [32:0] s;
      // слово з FIFO -> u_word (FWFT: f_data дійсне разом з f_valid)
      if (f_ready && f_valid) begin
        u_word <= f_data;
        u_have <= 1'b1;
        u_half <= 1'b0;
      end
      else if (out_hs) begin
        if (cfg_fmt8 && !u_half) u_half <= 1'b1;
        else u_have <= 1'b0;
      end
      // темп: тік -> один відлік
      s = {1'b0, rate_acc} + {1'b0, cfg_rate};
      rate_acc <= s[31:0];
      if (out_hs) pend <= s[32];
      else if (s[32]) pend <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || clr_under) under <= '0;
    else if (cfg_rate != 0 && rate_acc + cfg_rate < rate_acc && pend && !out_hs) under <= under + 1'b1;
    if (rst || clr_out) out_cnt <= '0;
    else if (out_hs) out_cnt <= out_cnt + 1'b1;
  end

  //------------------------------------------------------------- читання ---
  always_comb begin
    rd_data = '0;
    if (rd_addr[AW-1:9] == (AW-9)'(1)) rd_data = buf_mem[rd_addr[8:2]];
    else if (rd_addr[AW-1:9] == '0) begin
      case (rd_addr[8:0])
        9'h000: rd_data = {15'd0, cfg_fmt8, 3'd0, cfg_free, cfg_sdly, cfg_div};
        9'h004: rd_data = {11'd0, dat_iq, cmd_iq, 7'd0, d_err_wr, d_err_crc, d_err_tmo, c_err_crc, c_err_tmo,
                           1'b0, (ks != K_IDLE && d_stream), (ds != D_IDLE), (cs != C_IDLE || ks != K_IDLE)};
        9'h008: rd_data = cmd_arg;
        9'h010: rd_data = resp[31:0];
        9'h014: rd_data = resp[63:32];
        9'h018: rd_data = resp[95:64];
        9'h01C: rd_data = resp[127:96];
        9'h020: rd_data = st_lba;
        9'h024: rd_data = st_cnt;
        9'h02C: rd_data = d_done;
        9'h030: rd_data = 32'(f_level);
        9'h034: rd_data = cfg_rate;
        9'h038: rd_data = under;
        9'h03C: rd_data = ID_VALUE;
        9'h040: rd_data = out_cnt;
        default: ;
      endcase
    end
  end

  wire unused_ok = &{1'b0, rd_en, f_full, f_empty};

endmodule
