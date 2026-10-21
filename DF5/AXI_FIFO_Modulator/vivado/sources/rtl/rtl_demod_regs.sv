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

  rtl_demod_bank #(.ID_VALUE(ID_VALUE), .LUT_FILE(LUT_FILE)) u_bank (
    .s_axi_aclk, .s_axi_aresetn,
    .wr_en, .wr_addr (9'(wr_addr)), .wr_data, .wr_strb, .rd_addr (9'(rd_addr)), .rd_data,
    .s_axis_tvalid, .s_axis_tready, .s_axis_tdata,
    .irq,
    .tap_v (), .tap_burst (), .tap_start (), .tap_end (), .tap_bit_v (), .tap_bit (),
    .st_enable ()
  );

endmodule
