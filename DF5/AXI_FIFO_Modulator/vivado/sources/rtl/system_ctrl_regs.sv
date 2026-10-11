//==============================================================================
// system_ctrl_regs -- системні дрібниці в одному AXI4-Lite блоці:
// кнопки з антидребезгом, світлодіоди, програмований такт для SD-SPI,
// лічильник часу для софту, CS картки.
//
// Мапа регістрів (offset від базової адреси, 64 байти):
//   0x00  ID         RO  0x5359_5301 ("SYS" 01)
//   0x04  LED        RW  [1:0] світлодіоди (1 = світиться)
//   0x08  BTN_RAW    RO  [1:0] кнопки після антидребезгу, 1 = натиснута
//   0x0C  BTN_EVENT  R/W1C [1:0] защіпнуте натискання, [5:4] защіпнуте відпускання
//                          запис 1 у біт скидає його
//   0x10  SPI_CLKDIV RW  [7:0] spi_clk = aclk / (2*(DIV+1)); після скиду 63
//                        (100 МГц -> 781 кГц -> SCK 390 кГц при C_SCK_RATIO=2)
//   0x14  SD_CS      RW  [0] sd_cs_n (1 = картка не вибрана, стан після скиду)
//   0x18  TICK       RO  вільний лічильник тактів aclk (32 біти)
//   0x1C  SCRATCH    RW  для тестів шини
//   0x20  ACLK_HZ    RO  частота aclk у Гц (параметр) -- софт рахує мс з TICK
//   0x24  BTN_RAW_N  RO  [1:0] сирі (без антидребезгу) входи, для діагностики
//
// Кнопки на платі замкнені на землю з підтяжкою -> у залізо приходять
// активні нулем, тут інвертуються.
//==============================================================================
module system_ctrl_regs #(
  parameter int          C_S_AXI_ADDR_WIDTH = 6,
  parameter int          ACLK_HZ            = 100_000_000,
  parameter int          N_BTN              = 2,
  parameter int          N_LED              = 2,
  parameter int          DEBOUNCE_MS        = 8,
  parameter logic [31:0] ID_VALUE           = 32'h5359_5301
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

  input  logic [N_BTN-1:0]              btn_n,        // з плати, активні 0
  output logic [N_LED-1:0]              led,
  output logic                          sd_cs_n,
  output logic                          spi_clk_raw   // -> BUFG в обгортці
);

  localparam logic [C_S_AXI_ADDR_WIDTH-1:0]
    REG_ID = 6'h00, REG_LED = 6'h04, REG_BTN_RAW = 6'h08, REG_BTN_EVENT = 6'h0C,
    REG_SPI_CLKDIV = 6'h10, REG_SD_CS = 6'h14, REG_TICK = 6'h18, REG_SCRATCH = 6'h1C,
    REG_ACLK_HZ = 6'h20, REG_BTN_RAW_N = 6'h24;

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

  //--------------------------------------------------- антидребезг кнопок ---
  // Вхід синхронізуємо двома тригерами, далі семплюємо кожну мілісекунду
  // в зсувний регістр на 8 відліків; стан змінюється лише коли всі 8 збіглися.
  localparam int MS_TICKS = ACLK_HZ / 1000;

  logic [N_BTN-1:0] btn_sync0, btn_sync1;
  logic [$clog2(MS_TICKS)-1:0] ms_cnt;
  logic ms_tick;

  always_ff @(posedge s_axi_aclk) begin
    btn_sync0 <= ~btn_n;                      // активні 1 після інверсії
    btn_sync1 <= btn_sync0;
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      ms_cnt  <= '0;
      ms_tick <= 1'b0;
    end
    else if (ms_cnt == MS_TICKS - 1) begin
      ms_cnt  <= '0;
      ms_tick <= 1'b1;
    end
    else begin
      ms_cnt  <= ms_cnt + 1'b1;
      ms_tick <= 1'b0;
    end
  end

  logic [DEBOUNCE_MS-1:0] btn_hist [N_BTN];
  logic [N_BTN-1:0]       btn_db, btn_db_prev;
  logic [N_BTN-1:0]       ev_press, ev_release;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      for (int i = 0; i < N_BTN; i++) btn_hist[i] <= '0;
      btn_db      <= '0;
      btn_db_prev <= '0;
    end
    else begin
      btn_db_prev <= btn_db;
      if (ms_tick) begin
        for (int i = 0; i < N_BTN; i++) begin
          btn_hist[i] <= {btn_hist[i][DEBOUNCE_MS-2:0], btn_sync1[i]};
          if (&btn_hist[i])       btn_db[i] <= 1'b1;
          else if (~|btn_hist[i]) btn_db[i] <= 1'b0;
        end
      end
    end
  end

  wire [N_BTN-1:0] press_edge   =  btn_db & ~btn_db_prev;
  wire [N_BTN-1:0] release_edge = ~btn_db &  btn_db_prev;

  wire wr_btn_event = wr_en && (wr_addr == REG_BTN_EVENT) && wr_strb[0];

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      ev_press   <= '0;
      ev_release <= '0;
    end
    else begin
      // W1C і новий фронт в одному такті: фронт перемагає, щоб не загубити
      ev_press   <= (ev_press   & ~(wr_btn_event ? wr_data[N_BTN-1:0]   : '0)) | press_edge;
      ev_release <= (ev_release & ~(wr_btn_event ? wr_data[4 +: N_BTN]  : '0)) | release_edge;
    end
  end

  //------------------------------------------------------------ регістри ---
  logic [N_LED-1:0] led_q;
  logic [7:0]       spi_div;
  logic             sd_cs_n_q;
  logic [31:0]      tick, scratch;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      led_q     <= '0;
      spi_div   <= 8'd63;
      sd_cs_n_q <= 1'b1;
      scratch   <= '0;
    end
    else if (wr_en) begin
      case (wr_addr)
        REG_LED:        if (wr_strb[0]) led_q     <= wr_data[N_LED-1:0];
        REG_SPI_CLKDIV: if (wr_strb[0]) spi_div   <= wr_data[7:0];
        REG_SD_CS:      if (wr_strb[0]) sd_cs_n_q <= wr_data[0];
        REG_SCRATCH: begin
          if (wr_strb[0]) scratch[7:0]   <= wr_data[7:0];
          if (wr_strb[1]) scratch[15:8]  <= wr_data[15:8];
          if (wr_strb[2]) scratch[23:16] <= wr_data[23:16];
          if (wr_strb[3]) scratch[31:24] <= wr_data[31:24];
        end
        default: ;
      endcase
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) tick <= '0;
    else                tick <= tick + 1'b1;
  end

  assign led     = led_q;
  assign sd_cs_n = sd_cs_n_q;

  //------------------------------------------------------- такт для SPI ----
  // Регістровий вихід перемикається раз на (DIV+1) тактів -> без глітчів;
  // зміна DIV на льоту дає щонайбільше один подовжений півперіод.
  logic [7:0] spi_cnt;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      spi_cnt     <= '0;
      spi_clk_raw <= 1'b0;
    end
    else if (spi_cnt >= spi_div) begin
      spi_cnt     <= '0;
      spi_clk_raw <= ~spi_clk_raw;
    end
    else
      spi_cnt <= spi_cnt + 1'b1;
  end

  //------------------------------------------------------------- читання ---
  always_comb begin
    case (rd_addr)
      REG_ID:         rd_data = ID_VALUE;
      REG_LED:        rd_data = 32'(led_q);
      REG_BTN_RAW:    rd_data = 32'(btn_db);
      REG_BTN_EVENT:  rd_data = {24'd0, 2'd0, ev_release, 2'd0, ev_press};
      REG_SPI_CLKDIV: rd_data = 32'(spi_div);
      REG_SD_CS:      rd_data = 32'(sd_cs_n_q);
      REG_TICK:       rd_data = tick;
      REG_SCRATCH:    rd_data = scratch;
      REG_ACLK_HZ:    rd_data = 32'(ACLK_HZ);
      REG_BTN_RAW_N:  rd_data = 32'(btn_sync1);
      default:        rd_data = '0;
    endcase
  end

endmodule
