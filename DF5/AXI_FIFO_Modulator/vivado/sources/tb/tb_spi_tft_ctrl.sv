//==============================================================================
// tb_spi_tft_ctrl -- тестбенч SPI-контролера TFT.
//
// Перевіряє: ID, запис регістрів, частоту SCLK, порядок бітів (MSB first),
// поведінку DC, автоматичний CS, заповнення FIFO.
//
// Приймач SPI в тестбенчі збирає байти по наростаючому фронту SCLK
// і складає їх у чергу разом зі станом DC.
//==============================================================================
`timescale 1ns/1ps

module tb_spi_tft_ctrl;

  localparam int  ADDR_BW = 5;
  localparam int  DATA_BW = 32;
  localparam time CLK_P   = 10ns;        // 100 МГц

  localparam logic [31:0] ID_EXPECTED = 32'h5F77_8901;

  //==========================================================================
  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  logic [ADDR_BW-1:0]     awaddr;
  logic                   awvalid, awready;
  logic [DATA_BW-1:0]     wdata;
  logic [DATA_BW/8-1:0]   wstrb;
  logic                   wvalid, wready;
  logic [1:0]             bresp;
  logic                   bvalid, bready;
  logic [ADDR_BW-1:0]     araddr;
  logic                   arvalid, arready;
  logic [DATA_BW-1:0]     rdata;
  logic [1:0]             rresp;
  logic                   rvalid, rready;

  logic sclk, mosi, cs_n, dc, rst_n;
  logic miso = 1'b0;

  spi_tft_ctrl #(
    .C_S_AXI_ADDR_WIDTH (ADDR_BW),
    .C_S_AXI_DATA_WIDTH (DATA_BW),
    .FIFO_DEPTH         (16),
    .ID_VALUE           (ID_EXPECTED)
  ) dut (
    .s_axi_aclk (aclk), .s_axi_aresetn (arstn),
    .s_axi_awaddr (awaddr), .s_axi_awprot (3'b000),
    .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb),
    .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arprot (3'b000),
    .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp),
    .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .tft_sclk (sclk), .tft_mosi (mosi), .tft_miso (miso),
    .tft_cs_n (cs_n), .tft_dc (dc), .tft_rst_n (rst_n)
  );

  //==========================================================================
  // Статистика
  //==========================================================================
  int n_checks = 0;
  int n_errors = 0;

  task automatic chk(input string name, input logic [31:0] got, exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      $error("%s: очікувалось 0x%08h, отримано 0x%08h", name, exp, got);
    end
    else
      $display("%s: PASS (0x%08h)", name, got);
  endtask

  //==========================================================================
  // AXI4-Lite BFM
  //==========================================================================
  task automatic axi_write(input logic [ADDR_BW-1:0] addr,
                           input logic [DATA_BW-1:0] data);
    fork
      begin
        awaddr  <= addr;
        awvalid <= 1'b1;
        do @(posedge aclk); while (!awready);
        awvalid <= 1'b0;
      end
      begin
        wdata  <= data;
        wstrb  <= '1;
        wvalid <= 1'b1;
        do @(posedge aclk); while (!wready);
        wvalid <= 1'b0;
      end
      begin
        bready <= 1'b1;
        do @(posedge aclk); while (!bvalid);
        bready <= 1'b0;
      end
    join
  endtask

  task automatic axi_read(input  logic [ADDR_BW-1:0] addr,
                          output logic [DATA_BW-1:0] data);
    fork
      begin
        araddr  <= addr;
        arvalid <= 1'b1;
        do @(posedge aclk); while (!arready);
        arvalid <= 1'b0;
      end
      begin
        rready <= 1'b1;
        do @(posedge aclk); while (!rvalid);
        data = rdata;
        rready <= 1'b0;
      end
    join
  endtask

  //==========================================================================
  // Приймач SPI: збирає байт по наростаючому фронту SCLK
  //==========================================================================
  typedef struct {
    logic [7:0] data;
    logic       dc;
  } spi_item_t;

  spi_item_t rx_q [$];

  logic [7:0] rx_sh;
  int         rx_bits = 0;

  always @(posedge sclk) begin
    if (!cs_n) begin
      rx_sh   = {rx_sh[6:0], mosi};
      rx_bits = rx_bits + 1;
      if (rx_bits == 8) begin
        spi_item_t it;
        it.data = rx_sh;
        it.dc   = dc;
        rx_q.push_back(it);
        $display("[SPI-RX] @%0t byte=0x%02h dc=%0b", $time, it.data, it.dc);
        rx_bits = 0;
      end
    end
  end

  // CS між транзакціями має скидати лічильник бітів
  always @(posedge cs_n) rx_bits = 0;

  task automatic expect_byte(input string name,
                             input logic [7:0] data, input logic dcv);
    spi_item_t it;
    n_checks++;
    if (rx_q.size() == 0) begin
      n_errors++;
      $error("%s: приймач нічого не отримав", name);
      return;
    end
    it = rx_q.pop_front();
    if (it.data !== data || it.dc !== dcv) begin
      n_errors++;
      $error("%s: очікувалось 0x%02h dc=%0b, отримано 0x%02h dc=%0b",
             name, data, dcv, it.data, it.dc);
    end
    else
      $display("%s: PASS", name);
  endtask

  //==========================================================================
  // Вимірювання періоду SCLK
  //==========================================================================
  time t_prev = 0, t_meas = 0;
  always @(posedge sclk) begin
    if (t_prev != 0) t_meas = $time - t_prev;
    t_prev = $time;
  end

  //==========================================================================
  // Сценарій
  //==========================================================================
  logic [DATA_BW-1:0] v;

  initial begin
    awvalid <= 1'b0;  wvalid <= 1'b0;  bready <= 1'b0;
    arvalid <= 1'b0;  rready <= 1'b0;
    awaddr  <= '0;    araddr <= '0;    wstrb  <= '0;

    arstn = 1'b0;
    repeat (5) @(posedge aclk);
    arstn = 1'b1;
    repeat (2) @(posedge aclk);

    //------------------------------------------------------------------- T1
    $display("\n=== T1: ID і стан після скиду ===");
    axi_read(5'h10, v);  chk("ID", v, ID_EXPECTED);
    axi_read(5'h0C, v);  chk("STATUS: FIFO порожній, не busy",
                             v & 32'h7, 32'h4);
    chk("RESET дисплея знятий після скиду", {31'd0, rst_n}, 32'd1);

    //------------------------------------------------------------------- T2
    $display("\n=== T2: запис і зчитування регістрів ===");
    axi_write(5'h04, 32'd3);            // CLKDIV = 3 -> SCLK = aclk/8
    axi_read (5'h04, v);  chk("CLKDIV", v, 32'd3);

    axi_write(5'h00, 32'h15);           // enable|rst_n|cs_auto
    axi_read (5'h00, v);  chk("CTRL", v, 32'h15);
    chk("RESET дисплея знятий", {31'd0, rst_n}, 32'd1);

    //------------------------------------------------------------------- T3
    $display("\n=== T3: байт команди (DC = 0) ===");
    axi_write(5'h08, 32'h2C);           // RAMWR
    wait (rx_q.size() > 0);
    repeat (20) @(posedge aclk);
    expect_byte("команда 0x2C", 8'h2C, 1'b0);

    //------------------------------------------------------------------- T4
    $display("\n=== T4: перемикання DC і байт даних ===");
    axi_write(5'h00, 32'h17);           // той самий CTRL + DC = 1
    axi_write(5'h08, 32'hA5);
    wait (rx_q.size() > 0);
    repeat (20) @(posedge aclk);
    expect_byte("дані 0xA5", 8'hA5, 1'b1);

    //------------------------------------------------------------------- T5
    $display("\n=== T5: період SCLK ===");
    // CLKDIV = 3 -> півперіод = 4 такти -> період = 8 тактів = 80 нс
    n_checks++;
    if (t_meas != 80ns) begin
      n_errors++;
      $error("SCLK: очікувалось 80 нс, виміряно %0t", t_meas);
    end
    else
      $display("SCLK period = %0t: PASS", t_meas);

    //------------------------------------------------------------------- T6
    $display("\n=== T6: серія байтів, порядок збережено ===");
    axi_write(5'h08, 32'h01);
    axi_write(5'h08, 32'h23);
    axi_write(5'h08, 32'h45);
    axi_write(5'h08, 32'h67);
    wait (rx_q.size() >= 4);
    repeat (20) @(posedge aclk);
    expect_byte("серія [0]", 8'h01, 1'b1);
    expect_byte("серія [1]", 8'h23, 1'b1);
    expect_byte("серія [2]", 8'h45, 1'b1);
    expect_byte("серія [3]", 8'h67, 1'b1);

    //------------------------------------------------------------------- T7
    $display("\n=== T7: CS знімається після спорожнення FIFO ===");
    repeat (50) @(posedge aclk);
    chk("CS неактивний", {31'd0, cs_n}, 32'd1);

    //------------------------------------------------------------------- T8
    $display("\n=== T8: заповнення FIFO ===");
    axi_write(5'h00, 32'h16);           // enable = 0 -> передача стоїть
    for (int i = 0; i < 16; i++)
      axi_write(5'h08, 32'(i));
    axi_read(5'h0C, v);
    n_checks++;
    if (!(v & 32'h2)) begin
      n_errors++;
      $error("FIFO мав заповнитися, STATUS = 0x%08h", v);
    end
    else
      $display("tx_full виставлений: PASS");

    axi_write(5'h00, 32'h17);           // знову enable -> FIFO стікає
    repeat (2000) @(posedge aclk);
    axi_read(5'h0C, v);
    chk("FIFO спорожнів", v & 32'h4, 32'h4);

    //------------------------------------------------------------------- підсумок
    rx_q.delete();
    repeat (20) @(posedge aclk);

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "РЕЗУЛЬТАТ: PASS" : "РЕЗУЛЬТАТ: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  //==========================================================================
  initial begin
    #(CLK_P * 100000);
    $error("Watchdog: тест завис");
    $finish;
  end

  //==========================================================================
  // Протокольні перевірки
  //==========================================================================
`ifndef SYNTHESIS
  // DC не змінюється посеред байта
  assert property (@(posedge aclk) disable iff (!arstn)
    (dut.spi_state == 2'd2) |=> $stable(dc))
    else $error("DC змінився під час передачі байта");

  // CS активний, поки йде передача
  assert property (@(posedge aclk) disable iff (!arstn)
    (dut.spi_state == 2'd2 && dut.cfg_cs_auto) |-> !cs_n)
    else $error("CS неактивний під час передачі");
`endif

  initial begin
    $dumpfile("tb_spi_tft_ctrl.vcd");
    $dumpvars(0, tb_spi_tft_ctrl);
  end

endmodule
