//==============================================================================
// axi_lite_regs -- спільний міст AXI4-Lite -> проста шина регістрів.
//
// Використовується всіма новими периферійними блоками (iq_stream, rtl_demod,
// system_ctrl), щоб протокольна частина AXI була написана й перевірена один раз.
//
// Шина регістрів з боку користувача:
//   wr_en   -- одиночний імпульс, коли адреса і дані запису прийняті
//   wr_addr -- байтова адреса (молодші 2 біти завжди 0)
//   wr_data / wr_strb
//   rd_en   -- одиночний імпульс: rd_data має бути комбінаційно виставлено
//              за rd_addr у ТОМУ Ж такті (защіпується в s_axi_rdata)
//   rd_req / rd_req_addr -- на такт раніше (AR прийнято): для синхронних
//              BRAM, які видають дані з затримкою в один такт
//
// Усі відповіді OKAY; адреса поза мапою -- справа користувача (читати 0).
//==============================================================================
module axi_lite_regs #(
  parameter int ADDR_WIDTH = 8
)(
  input  logic                  s_axi_aclk,
  input  logic                  s_axi_aresetn,

  input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic [2:0]            s_axi_awprot,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,
  input  logic [31:0]           s_axi_wdata,
  input  logic [3:0]            s_axi_wstrb,
  input  logic                  s_axi_wvalid,
  output logic                  s_axi_wready,
  output logic [1:0]            s_axi_bresp,
  output logic                  s_axi_bvalid,
  input  logic                  s_axi_bready,

  input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic [2:0]            s_axi_arprot,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,
  output logic [31:0]           s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready,

  output logic                  wr_en,
  output logic [ADDR_WIDTH-1:0] wr_addr,
  output logic [31:0]           wr_data,
  output logic [3:0]            wr_strb,
  output logic                  rd_en,
  output logic [ADDR_WIDTH-1:0] rd_addr,
  input  logic [31:0]           rd_data,
  output logic                  rd_req,
  output logic [ADDR_WIDTH-1:0] rd_req_addr
);

  //-------------------------------------------------------------- запис ----
  // AW і W можуть прийти в будь-якому порядку; транзакція виконується,
  // коли обидва канали прийняті, і займає рівно один такт (wr_en).
  logic                  aw_done, w_done;
  logic [ADDR_WIDTH-1:0] aw_q;
  logic [31:0]           w_q;
  logic [3:0]            strb_q;

  wire aw_hs = s_axi_awvalid && s_axi_awready;
  wire w_hs  = s_axi_wvalid  && s_axi_wready;

  assign s_axi_awready = !aw_done && !s_axi_bvalid;
  assign s_axi_wready  = !w_done  && !s_axi_bvalid;

  assign wr_en   = (aw_done || aw_hs) && (w_done || w_hs) && !s_axi_bvalid;
  assign wr_addr = aw_hs ? {s_axi_awaddr[ADDR_WIDTH-1:2], 2'b00} : aw_q;
  assign wr_data = w_hs  ? s_axi_wdata : w_q;
  assign wr_strb = w_hs  ? s_axi_wstrb : strb_q;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end
    else if (wr_en) begin
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end
    else begin
      if (aw_hs) aw_done <= 1'b1;
      if (w_hs)  w_done  <= 1'b1;
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (aw_hs) aw_q <= {s_axi_awaddr[ADDR_WIDTH-1:2], 2'b00};
    if (w_hs) begin
      w_q    <= s_axi_wdata;
      strb_q <= s_axi_wstrb;
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn)                 s_axi_bvalid <= 1'b0;
    else if (wr_en)                     s_axi_bvalid <= 1'b1;
    else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
  end

  assign s_axi_bresp = 2'b00;

  //------------------------------------------------------------ читання ----
  // Такт 0: AR прийнято, адреса защіпнута. Такт 1: rd_en, дані защіпуються
  // в s_axi_rdata, rvalid. Отже користувацька логіка бачить стабільну
  // rd_addr цілий такт перед тим, як її rd_data буде зчитано.
  logic rd_pending;

  wire ar_hs = s_axi_arvalid && s_axi_arready;

  assign s_axi_arready = !rd_pending && !s_axi_rvalid;
  assign rd_en         = rd_pending;
  assign rd_req        = ar_hs;
  assign rd_req_addr   = {s_axi_araddr[ADDR_WIDTH-1:2], 2'b00};

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      rd_pending   <= 1'b0;
      s_axi_rvalid <= 1'b0;
      rd_addr      <= '0;
      s_axi_rdata  <= '0;
    end
    else begin
      if (ar_hs) begin
        rd_addr    <= {s_axi_araddr[ADDR_WIDTH-1:2], 2'b00};
        rd_pending <= 1'b1;
      end
      if (rd_pending) begin
        rd_pending   <= 1'b0;
        s_axi_rdata  <= rd_data;
        s_axi_rvalid <= 1'b1;
      end
      else if (s_axi_rvalid && s_axi_rready)
        s_axi_rvalid <= 1'b0;
    end
  end

  assign s_axi_rresp = 2'b00;

endmodule
