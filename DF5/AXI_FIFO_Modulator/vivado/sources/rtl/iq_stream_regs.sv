//==============================================================================
// iq_stream_regs -- AXI4-Lite обгортка над iq_stream_fifo: MicroBlaze пише
// пари I/Q, вихід іде потоком (AXI-Stream) у rtl_demod.
//
// Мапа регістрів (offset від базової адреси, 32 байти):
//   0x00  CTRL     [0] enable     RW  вихідний потік дозволено (при 0 FIFO
//                                     накопичує, демодулятор нічого не бачить)
//                  [1] flush      W   імпульс: скинути FIFO і прапор overflow
//                  [2] clr_stats  W   імпульс: обнулити лічильники
//   0x04  STATUS   [0] empty      RO
//                  [1] full       RO
//                  [2] overflow   RO  запис у повний FIFO був проігнорований
//                                     (скидається flush)
//                  [3] enable     RO
//                  [31:16] level  RO  слів у FIFO
//   0x08  DATA     [15:0] I, [31:16] Q  W  штовхає одну пару в FIFO
//                                      R  слово на виході FIFO (без вилучення)
//   0x0C  LEVEL    RO  слів у FIFO
//   0x10  PUSHED   RO  прийнято пар від CPU
//   0x14  POPPED   RO  віддано пар демодулятору
//   0x18  DROPPED  RO  відкинуто записів через full
//   0x1C  ID       RO  0x4951_0001  ("IQ" 00 01)
//
// Один запис DATA -- одна повна пара I/Q, тож неповна пара в DSP потрапити
// не може (вимога ТЗ 3.2).
//==============================================================================
module iq_stream_regs #(
  parameter int          C_S_AXI_ADDR_WIDTH = 5,
  parameter int          FIFO_DEPTH         = 1024,
  parameter logic [31:0] ID_VALUE           = 32'h4951_0001
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

  // потік до демодулятора
  output logic                          m_axis_tvalid,
  input  logic                          m_axis_tready,
  output logic [31:0]                   m_axis_tdata
);

  localparam logic [C_S_AXI_ADDR_WIDTH-1:0]
    REG_CTRL    = 5'h00, REG_STATUS = 5'h04, REG_DATA   = 5'h08, REG_LEVEL = 5'h0C,
    REG_PUSHED  = 5'h10, REG_POPPED = 5'h14, REG_DROPPED = 5'h18, REG_ID   = 5'h1C;

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

  //---------------------------------------------------------------- FIFO ---
  logic                     cfg_enable;
  logic                     flush, clr_stats;
  logic                     fifo_full, fifo_empty, fifo_valid;
  logic [$clog2(FIFO_DEPTH):0] fifo_level;
  logic [31:0]              fifo_data;

  wire push = wr_en && (wr_addr == REG_DATA);
  wire pop  = fifo_valid && m_axis_tready && cfg_enable;

  iq_stream_fifo #(.WIDTH(32), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk     (s_axi_aclk),
    .rst     (!s_axi_aresetn || flush),
    .wr_en   (push),
    .wr_data (wr_data),
    .full    (fifo_full),
    .m_valid (fifo_valid),
    .m_ready (m_axis_tready && cfg_enable),
    .m_data  (fifo_data),
    .empty   (fifo_empty),
    .level   (fifo_level)
  );

  assign m_axis_tvalid = fifo_valid && cfg_enable;
  assign m_axis_tdata  = fifo_data;

  //------------------------------------------------------------ регістри ---
  logic        overflow;
  logic [31:0] cnt_pushed, cnt_popped, cnt_dropped;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cfg_enable <= 1'b0;
      flush      <= 1'b0;
      clr_stats  <= 1'b0;
    end
    else begin
      flush     <= 1'b0;
      clr_stats <= 1'b0;
      if (wr_en && wr_addr == REG_CTRL && wr_strb[0]) begin
        cfg_enable <= wr_data[0];
        flush      <= wr_data[1];
        clr_stats  <= wr_data[2];
      end
    end
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn || flush) overflow <= 1'b0;
    else if (push && fifo_full)  overflow <= 1'b1;
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn || clr_stats) begin
      cnt_pushed  <= '0;
      cnt_popped  <= '0;
      cnt_dropped <= '0;
    end
    else begin
      if (push && !fifo_full) cnt_pushed  <= cnt_pushed + 1'b1;
      if (push &&  fifo_full) cnt_dropped <= cnt_dropped + 1'b1;
      if (pop)                cnt_popped  <= cnt_popped + 1'b1;
    end
  end

  always_comb begin
    case (rd_addr)
      REG_CTRL:    rd_data = {31'd0, cfg_enable};
      REG_STATUS:  rd_data = {16'(fifo_level), 12'd0, cfg_enable, overflow, fifo_full, fifo_empty};
      REG_DATA:    rd_data = fifo_data;
      REG_LEVEL:   rd_data = 32'(fifo_level);
      REG_PUSHED:  rd_data = cnt_pushed;
      REG_POPPED:  rd_data = cnt_popped;
      REG_DROPPED: rd_data = cnt_dropped;
      REG_ID:      rd_data = ID_VALUE;
      default:     rd_data = '0;
    endcase
  end

endmodule
