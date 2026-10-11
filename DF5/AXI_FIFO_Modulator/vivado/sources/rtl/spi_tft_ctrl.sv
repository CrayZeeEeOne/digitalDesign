//==============================================================================
// spi_tft_ctrl -- AXI4-Lite SPI master для TFT (ST7789).
//
// Роль: простий байтовий транспорт. Команди/дані розрізняє софт через
// біт DC; уся логіка дисплея живе в C-драйвері.
//
// Мапа регістрів (offset від базової адреси):
//   0x00  CTRL    [0] enable      RW  вмикає SPI (при 0 SCLK стоїть)
//                 [1] dc          RW  0 = команда, 1 = дані
//                 [2] rst_n       RW  апаратний скид дисплея, активний 0
//                 [3] cs_n        RW  ручне керування CS (0 = активний)
//                 [4] cs_auto     RW  1 = CS тримається автоматично,
//                                     поки FIFO непорожній
//                 [5] blk         RW  підсвітка, 1 = увімкнена
//   0x04  CLKDIV  [15:0]          RW  f_sclk = f_aclk / (2*(CLKDIV+1))
//   0x08  TXDATA  [7:0]           W   запис штовхає байт у TX FIFO
//                 [7:0]           R   останній прийнятий байт (MISO)
//   0x0C  STATUS  [0] busy        RO  іде передача
//                 [1] tx_full     RO
//                 [2] tx_empty    RO
//                 [8:4] tx_level  RO  скільки байтів у FIFO (0..FIFO_DEPTH)
//   0x10  ID      0x5F7789xx      RO  магічне число для bring-up
//
// Порти дисплея скалярні -- у .xdc пишуться без квадратних дужок.
//==============================================================================
module spi_tft_ctrl #(
  parameter int          C_S_AXI_ADDR_WIDTH = 5,    // 8 регістрів = 32 байти
  parameter int          C_S_AXI_DATA_WIDTH = 32,
  parameter int          FIFO_DEPTH         = 16,
  parameter logic [31:0] ID_VALUE           = 32'h5F77_8901
)(
  input  logic                              s_axi_aclk,
  input  logic                              s_axi_aresetn,

  //------------------------------------------------------ AXI4-Lite, запис
  input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
  input  logic [2:0]                        s_axi_awprot,
  input  logic                              s_axi_awvalid,
  output logic                              s_axi_awready,

  input  logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
  input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
  input  logic                              s_axi_wvalid,
  output logic                              s_axi_wready,

  output logic [1:0]                        s_axi_bresp,
  output logic                              s_axi_bvalid,
  input  logic                              s_axi_bready,

  //---------------------------------------------------- AXI4-Lite, читання
  input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
  input  logic [2:0]                        s_axi_arprot,
  input  logic                              s_axi_arvalid,
  output logic                              s_axi_arready,

  output logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
  output logic [1:0]                        s_axi_rresp,
  output logic                              s_axi_rvalid,
  input  logic                              s_axi_rready,

  //---------------------------------------------------------- до дисплея
  output logic                              tft_sclk,
  output logic                              tft_mosi,
  input  logic                              tft_miso,   // не всі модулі мають
  output logic                              tft_cs_n,
  output logic                              tft_dc,
  output logic                              tft_rst_n,
  output logic                              tft_blk      // підсвітка
);

  localparam int STRB_BW  = C_S_AXI_DATA_WIDTH/8;
  localparam int ADDR_LSB = $clog2(STRB_BW);
  localparam int REG_BITS = C_S_AXI_ADDR_WIDTH - ADDR_LSB;
  localparam int PTR_BW   = $clog2(FIFO_DEPTH);

  localparam logic [2:0] REG_CTRL   = 3'd0;
  localparam logic [2:0] REG_CLKDIV = 3'd1;
  localparam logic [2:0] REG_TXDATA = 3'd2;
  localparam logic [2:0] REG_STATUS = 3'd3;
  localparam logic [2:0] REG_ID     = 3'd4;

  localparam logic [1:0] RESP_OKAY = 2'b00;

  //==========================================================================
  // Регістри керування
  //==========================================================================
  logic        cfg_enable;
  logic        cfg_dc;
  logic        cfg_rst_n;
  logic        cfg_cs_n;
  logic        cfg_cs_auto;
  logic        cfg_blk;
  logic [15:0] cfg_clkdiv;

  //==========================================================================
  // TX FIFO
  //==========================================================================
  logic [7:0]        fifo_mem [0:FIFO_DEPTH-1];
  logic [PTR_BW:0]   wr_ptr, rd_ptr;          // зайвий біт -- для full/empty
  logic              fifo_push, fifo_pop;
  logic [7:0]        fifo_din;

  wire [PTR_BW:0] fifo_level = wr_ptr - rd_ptr;
  // Порівнюємо в повній ширині PTR_BW+1: кастинг FIFO_DEPTH до PTR_BW біт
  // дав би 0 і "full" збігався б із "empty".
  wire            fifo_full  = (fifo_level == (PTR_BW+1)'(FIFO_DEPTH));
  wire            fifo_empty = (fifo_level == '0);

  always_ff @(posedge s_axi_aclk) begin
    if (fifo_push) fifo_mem[wr_ptr[PTR_BW-1:0]] <= fifo_din;
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end
    else begin
      if (fifo_push && !fifo_full) wr_ptr <= wr_ptr + 1'b1;
      if (fifo_pop  && !fifo_empty) rd_ptr <= rd_ptr + 1'b1;
    end
  end

  wire [7:0] fifo_dout = fifo_mem[rd_ptr[PTR_BW-1:0]];

  //==========================================================================
  // SPI shift engine, режим 0: CPOL=0, CPHA=0, MSB first
  //
  //   дані виставляються по спаду SCLK, семпляться приймачем по фронту
  //==========================================================================
  typedef enum logic [1:0] {
    SPI_IDLE,
    SPI_LOAD,
    SPI_SHIFT
  } spi_state_t;

  spi_state_t  spi_state;
  logic [7:0]  sh_tx, sh_rx;
  logic [3:0]  bit_cnt;
  logic [15:0] clk_cnt;
  logic        sclk_r;

  wire tick = (clk_cnt == cfg_clkdiv);   // півперіод SCLK

  assign fifo_pop = (spi_state == SPI_LOAD);

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      spi_state <= SPI_IDLE;
      sclk_r    <= 1'b0;
      bit_cnt   <= '0;
      clk_cnt   <= '0;
      sh_tx     <= '0;
      sh_rx     <= '0;
    end
    else begin
      case (spi_state)
        //------------------------------------------------------------ IDLE
        SPI_IDLE: begin
          sclk_r  <= 1'b0;
          clk_cnt <= '0;
          if (cfg_enable && !fifo_empty) spi_state <= SPI_LOAD;
        end

        //------------------------------------------------------------ LOAD
        SPI_LOAD: begin
          sh_tx     <= fifo_dout;      // fifo_pop активний саме тут
          bit_cnt   <= 4'd8;
          clk_cnt   <= '0;
          sclk_r    <= 1'b0;
          spi_state <= SPI_SHIFT;
        end

        //----------------------------------------------------------- SHIFT
        SPI_SHIFT: begin
          if (tick) begin
            clk_cnt <= '0;
            sclk_r  <= ~sclk_r;

            if (!sclk_r) begin
              // наростаючий фронт -- приймач захоплює MOSI, ми читаємо MISO
              sh_rx <= {sh_rx[6:0], tft_miso};
            end
            else begin
              // спадний фронт -- зсуваємо наступний біт
              sh_tx   <= {sh_tx[6:0], 1'b0};
              bit_cnt <= bit_cnt - 1'b1;
              if (bit_cnt == 4'd1)
                spi_state <= (cfg_enable && !fifo_empty) ? SPI_LOAD : SPI_IDLE;
            end
          end
          else clk_cnt <= clk_cnt + 1'b1;
        end

        default: spi_state <= SPI_IDLE;
      endcase
    end
  end

  wire spi_busy = (spi_state != SPI_IDLE);

  //==========================================================================
  // Виходи на дисплей
  //==========================================================================
  assign tft_sclk = sclk_r;
  assign tft_mosi = sh_tx[7];
  assign tft_dc   = cfg_dc;
  assign tft_rst_n = cfg_rst_n;
  assign tft_blk   = cfg_blk;
  // в авторежимі CS активний, поки є що передавати
  assign tft_cs_n = cfg_cs_auto ? ~(spi_busy || !fifo_empty) : cfg_cs_n;

  //==========================================================================
  // AXI4-Lite: канал запису
  //==========================================================================
  logic                          aw_done, w_done;
  logic [REG_BITS-1:0]           aw_reg;
  logic [C_S_AXI_DATA_WIDTH-1:0] w_reg;
  logic [STRB_BW-1:0]            strb_reg;

  wire aw_hs = s_axi_awvalid && s_axi_awready;
  wire w_hs  = s_axi_wvalid  && s_axi_wready;
  wire b_hs  = s_axi_bvalid  && s_axi_bready;

  assign s_axi_awready = !aw_done && !s_axi_bvalid;
  assign s_axi_wready  = !w_done  && !s_axi_bvalid;

  wire do_write = (aw_done || aw_hs) && (w_done || w_hs) && !s_axi_bvalid;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end
    else if (do_write) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end
    else begin
      if (aw_hs) aw_done <= 1'b1;
      if (w_hs)  w_done  <= 1'b1;
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (aw_hs) aw_reg <= s_axi_awaddr[ADDR_LSB +: REG_BITS];
    if (w_hs) begin
      w_reg    <= s_axi_wdata;
      strb_reg <= s_axi_wstrb;
    end
  end

  wire [REG_BITS-1:0]           wr_reg  = aw_hs ? s_axi_awaddr[ADDR_LSB +: REG_BITS] : aw_reg;
  wire [C_S_AXI_DATA_WIDTH-1:0] wr_data = w_hs  ? s_axi_wdata : w_reg;
  wire [STRB_BW-1:0]            wr_strb = w_hs  ? s_axi_wstrb : strb_reg;

  // штовхаємо в FIFO лише при записі в TXDATA і якщо є місце
  assign fifo_push = do_write && (wr_reg[2:0] == REG_TXDATA)
                     && wr_strb[0] && !fifo_full;
  assign fifo_din  = wr_data[7:0];

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cfg_enable  <= 1'b0;
      cfg_dc      <= 1'b0;
      cfg_rst_n   <= 1'b0;     // дисплей тримається в скиді до ініціалізації
      cfg_cs_n    <= 1'b1;
      cfg_cs_auto <= 1'b1;
      cfg_blk     <= 1'b0;     // підсвітка вимкнена до ініціалізації
      cfg_clkdiv  <= 16'd1;    // 100 МГц / 4 = 25 МГц
    end
    else if (do_write) begin
      case (wr_reg[2:0])
        REG_CTRL: if (wr_strb[0]) begin
          cfg_enable  <= wr_data[0];
          cfg_dc      <= wr_data[1];
          cfg_rst_n   <= wr_data[2];
          cfg_cs_n    <= wr_data[3];
          cfg_cs_auto <= wr_data[4];
          cfg_blk     <= wr_data[5];
        end
        REG_CLKDIV: begin
          if (wr_strb[0]) cfg_clkdiv[7:0]  <= wr_data[7:0];
          if (wr_strb[1]) cfg_clkdiv[15:8] <= wr_data[15:8];
        end
        default: ;   // TXDATA обробляється через fifo_push, решта RO
      endcase
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) s_axi_bvalid <= 1'b0;
    else if (do_write)  s_axi_bvalid <= 1'b1;
    else if (b_hs)      s_axi_bvalid <= 1'b0;
  end

  assign s_axi_bresp = RESP_OKAY;

  //==========================================================================
  // AXI4-Lite: канал читання
  //==========================================================================
  wire ar_hs = s_axi_arvalid && s_axi_arready;
  wire r_hs  = s_axi_rvalid  && s_axi_rready;

  assign s_axi_arready = !s_axi_rvalid;

  logic [REG_BITS-1:0] ar_reg;

  always_ff @(posedge s_axi_aclk) begin
    if (ar_hs) ar_reg <= s_axi_araddr[ADDR_LSB +: REG_BITS];
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) s_axi_rvalid <= 1'b0;
    else if (ar_hs)     s_axi_rvalid <= 1'b1;
    else if (r_hs)      s_axi_rvalid <= 1'b0;
  end

  always_comb begin
    case (ar_reg[2:0])
      REG_CTRL:   s_axi_rdata = {26'd0, cfg_blk, cfg_cs_auto, cfg_cs_n,
                                 cfg_rst_n, cfg_dc, cfg_enable};
      REG_CLKDIV: s_axi_rdata = {16'd0, cfg_clkdiv};
      REG_TXDATA: s_axi_rdata = {24'd0, sh_rx};
      REG_STATUS: s_axi_rdata = {23'd0, 5'(fifo_level),
                                 1'b0, fifo_empty, fifo_full, spi_busy};
      REG_ID:     s_axi_rdata = ID_VALUE;
      default:    s_axi_rdata = '0;
    endcase
  end

  assign s_axi_rresp = RESP_OKAY;

endmodule
