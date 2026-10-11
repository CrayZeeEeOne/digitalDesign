//==============================================================================
// tb_system_ctrl -- тестбенч system_ctrl_regs: регістри, антидребезг кнопок,
// події натискання/відпускання з W1C, дільник такту SPI, лічильник TICK.
//
// Щоб не чекати мілісекунди, ACLK_HZ задано 1 МГц -> 1 мс = 1000 тактів.
//==============================================================================
`timescale 1ns/1ps

module tb_system_ctrl;

  localparam int  ADDR_BW = 6;
  localparam time CLK_P   = 10ns;
  localparam int  ACLK_HZ = 1_000_000;

  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  logic [ADDR_BW-1:0] awaddr, araddr;
  logic               awvalid, awready, wvalid, wready, bvalid, bready;
  logic               arvalid, arready, rvalid, rready;
  logic [31:0]        wdata, rdata;
  logic [3:0]         wstrb;
  logic [1:0]         bresp, rresp;

  logic [1:0] btn_n;
  logic [1:0] led;
  logic       sd_cs_n, spi_clk;

  system_ctrl_regs #(.C_S_AXI_ADDR_WIDTH(ADDR_BW), .ACLK_HZ(ACLK_HZ)) dut (
    .s_axi_aclk (aclk), .s_axi_aresetn (arstn),
    .s_axi_awaddr (awaddr), .s_axi_awprot (3'b000), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arprot (3'b000), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .btn_n (btn_n), .led (led), .sd_cs_n (sd_cs_n), .spi_clk_raw (spi_clk)
  );

  int n_checks = 0, n_errors = 0;

  task automatic chk(input string name, input logic [31:0] got, exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      $error("%s: очікувалось 0x%08h, отримано 0x%08h", name, exp, got);
    end
    else
      $display("%s: PASS (0x%08h)", name, got);
  endtask

  task automatic axi_write(input logic [ADDR_BW-1:0] addr, input logic [31:0] data);
    fork
      begin awaddr <= addr; awvalid <= 1; do @(posedge aclk); while (!awready); awvalid <= 0; end
      begin wdata <= data; wstrb <= '1; wvalid <= 1; do @(posedge aclk); while (!wready); wvalid <= 0; end
      begin bready <= 1; do @(posedge aclk); while (!bvalid); bready <= 0; end
    join
  endtask

  task automatic axi_read(input logic [ADDR_BW-1:0] addr, output logic [31:0] data);
    fork
      begin araddr <= addr; arvalid <= 1; do @(posedge aclk); while (!arready); arvalid <= 0; end
      begin rready <= 1; do @(posedge aclk); while (!rvalid); data = rdata; rready <= 0; end
    join
  endtask

  // дребезг: кілька швидких перемикань перед стабільним станом
  task automatic press_with_bounce(input int idx);
    for (int k = 0; k < 6; k++) begin
      btn_n[idx] = ~btn_n[idx];
      #(CLK_P * $urandom_range(50, 400));
    end
    btn_n[idx] = 1'b0;                                   // натиснуто (активний 0)
  endtask

  // період spi_clk
  time t_prev = 0, t_period = 0;
  always @(posedge spi_clk) begin
    if (t_prev != 0) t_period = $time - t_prev;
    t_prev = $time;
  end

  logic [31:0] v, t0, t1;

  initial begin
    awvalid <= 0; wvalid <= 0; bready <= 0; arvalid <= 0; rready <= 0;
    awaddr <= '0; araddr <= '0; wdata <= '0; wstrb <= '0;
    btn_n = 2'b11;

    arstn = 0; repeat (5) @(posedge aclk); arstn = 1; repeat (2) @(posedge aclk);

    $display("\n=== T1: регістри ===");
    axi_read(6'h00, v); chk("ID", v, 32'h5359_5301);
    axi_read(6'h20, v); chk("ACLK_HZ", v, 32'(ACLK_HZ));
    axi_write(6'h04, 32'h2); axi_read(6'h04, v); chk("LED", v, 32'h2);
    chk("led вихід", 32'(led), 32'h2);
    axi_write(6'h1C, 32'hDEAD_BEEF); axi_read(6'h1C, v); chk("SCRATCH", v, 32'hDEAD_BEEF);
    axi_read(6'h14, v); chk("SD_CS після скиду = 1", v, 32'h1);
    chk("sd_cs_n вихід", 32'(sd_cs_n), 32'h1);
    axi_write(6'h14, 32'h0); chk("sd_cs_n = 0 після запису", 32'(sd_cs_n), 32'h0);
    axi_read(6'h10, v); chk("SPI_CLKDIV після скиду", v, 32'd63);

    $display("\n=== T2: TICK іде ===");
    axi_read(6'h18, t0); repeat (100) @(posedge aclk); axi_read(6'h18, t1);
    n_checks++;
    if (t1 - t0 < 100 || t1 - t0 > 120) begin n_errors++; $error("TICK: %0d за ~100 тактів", t1 - t0); end
    else $display("TICK +%0d за ~100 тактів: PASS", t1 - t0);

    $display("\n=== T3: кнопка з дребезгом ===");
    axi_read(6'h08, v); chk("BTN_RAW: не натиснуто", v, 32'h0);
    press_with_bounce(0);
    #(CLK_P * 1000 * 12);                                // > 8 мс стабільного стану
    axi_read(6'h08, v); chk("BTN_RAW: KEY1 натиснуто", v, 32'h1);
    axi_read(6'h0C, v); chk("BTN_EVENT: одна подія press", v, 32'h01);
    axi_write(6'h0C, 32'h01);                            // W1C
    axi_read(6'h0C, v); chk("BTN_EVENT після W1C", v, 32'h00);
    btn_n[0] = 1'b1;                                     // відпустили
    #(CLK_P * 1000 * 12);
    axi_read(6'h08, v); chk("BTN_RAW: відпущено", v, 32'h0);
    axi_read(6'h0C, v); chk("BTN_EVENT: release", v, 32'h10);
    axi_write(6'h0C, 32'h10);
    // коротке "брязкання" < 8 мс не має дати події
    btn_n[1] = 1'b0; #(CLK_P * 1000 * 3); btn_n[1] = 1'b1; #(CLK_P * 1000 * 10);
    axi_read(6'h0C, v); chk("BTN_EVENT: короткий імпульс відфільтровано", v, 32'h00);

    $display("\n=== T4: дільник SPI ===");
    axi_write(6'h10, 32'd3);                             // період = 2*(3+1) = 8 тактів
    #(CLK_P * 100);
    n_checks++;
    if (t_period != CLK_P * 8) begin n_errors++; $error("spi_clk період %0t, очікувалось %0t", t_period, CLK_P * 8); end
    else $display("spi_clk період %0t при DIV=3: PASS", t_period);
    axi_write(6'h10, 32'd0);                             // період = 2 такти
    #(CLK_P * 50);
    n_checks++;
    if (t_period != CLK_P * 2) begin n_errors++; $error("spi_clk період %0t, очікувалось %0t", t_period, CLK_P * 2); end
    else $display("spi_clk період %0t при DIV=0: PASS", t_period);

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "РЕЗУЛЬТАТ: PASS" : "РЕЗУЛЬТАТ: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  initial begin
    #(CLK_P * 2_000_000);
    $error("Watchdog: тест завис");
    $finish;
  end

endmodule
