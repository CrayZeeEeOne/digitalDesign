//==============================================================================
// tb_iq_stream -- тестбенч iq_stream_regs: запис пар I/Q через AXI4-Lite,
// рівень, full/overflow, порядок на виході, flush, лічильники.
//==============================================================================
`timescale 1ns/1ps

module tb_iq_stream;

  localparam int  ADDR_BW = 5;
  localparam int  DEPTH   = 16;          // маленький FIFO, щоб швидко заповнити
  localparam time CLK_P   = 10ns;

  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  logic [ADDR_BW-1:0] awaddr, araddr;
  logic               awvalid, awready, wvalid, wready, bvalid, bready;
  logic               arvalid, arready, rvalid, rready;
  logic [31:0]        wdata, rdata;
  logic [3:0]         wstrb;
  logic [1:0]         bresp, rresp;

  logic        m_tvalid, m_tready;
  logic [31:0] m_tdata;

  iq_stream_regs #(.C_S_AXI_ADDR_WIDTH(ADDR_BW), .FIFO_DEPTH(DEPTH)) dut (
    .s_axi_aclk (aclk), .s_axi_aresetn (arstn),
    .s_axi_awaddr (awaddr), .s_axi_awprot (3'b000), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arprot (3'b000), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .m_axis_tvalid (m_tvalid), .m_axis_tready (m_tready), .m_axis_tdata (m_tdata)
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

  //-------------------------------------------------- приймач потоку -------
  logic [31:0] rx_q [$];
  always @(posedge aclk) if (m_tvalid && m_tready) rx_q.push_back(m_tdata);

  // випадковий ready, щоб перевірити FWFT-логіку під тиском
  always @(posedge aclk) m_tready <= ($urandom_range(0, 2) != 0);

  logic [31:0] v;

  initial begin
    awvalid <= 0; wvalid <= 0; bready <= 0; arvalid <= 0; rready <= 0;
    awaddr <= '0; araddr <= '0; wdata <= '0; wstrb <= '0;
    m_tready <= 0;

    arstn = 0; repeat (5) @(posedge aclk); arstn = 1; repeat (2) @(posedge aclk);

    $display("\n=== T1: ID і стан після скиду ===");
    axi_read(5'h1C, v); chk("ID", v, 32'h4951_0001);
    axi_read(5'h04, v); chk("STATUS: empty, не enable", v & 32'hF, 32'h1);

    $display("\n=== T2: заповнення при enable=0, overflow ===");
    for (int i = 0; i < DEPTH + 3; i++)
      axi_write(5'h08, {16'(1000 + i), 16'(i)});       // Q = 1000+i, I = i
    axi_read(5'h0C, v); chk("LEVEL = DEPTH", v, 32'(DEPTH));
    axi_read(5'h04, v); chk("STATUS: full|overflow", v & 32'hF, 32'h6);
    axi_read(5'h10, v); chk("PUSHED", v, 32'(DEPTH));
    axi_read(5'h18, v); chk("DROPPED", v, 32'd3);
    chk("потік мовчить без enable", {31'd0, m_tvalid}, 32'd0);

    $display("\n=== T3: enable -> дані виходять по порядку ===");
    axi_write(5'h00, 32'h1);
    repeat (200) @(posedge aclk);
    chk("прийнято слів", 32'(rx_q.size()), 32'(DEPTH));
    for (int i = 0; i < DEPTH && i < rx_q.size(); i++)
      if (rx_q[i] !== {16'(1000 + i), 16'(i)}) begin
        n_errors++;
        $error("слово %0d: 0x%08h, очікувалось 0x%08h", i, rx_q[i], {16'(1000 + i), 16'(i)});
      end
    n_checks++;
    axi_read(5'h14, v); chk("POPPED", v, 32'(DEPTH));
    axi_read(5'h04, v); chk("STATUS: empty + enable, overflow досі", v & 32'hF, 32'h9 | 32'h4);

    $display("\n=== T4: flush скидає overflow ===");
    axi_write(5'h00, 32'h3);
    axi_read(5'h04, v); chk("STATUS після flush", v & 32'hF, 32'h9);

    $display("\n=== T5: потокова передача з паузами ===");
    rx_q.delete();
    for (int i = 0; i < 100; i++) begin
      axi_write(5'h08, 32'(i) * 32'h0001_0003);
      if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 6)) @(posedge aclk);
    end
    repeat (300) @(posedge aclk);
    chk("прийнято 100 слів", 32'(rx_q.size()), 32'd100);
    n_checks++;
    for (int i = 0; i < 100 && i < rx_q.size(); i++)
      if (rx_q[i] !== 32'(i) * 32'h0001_0003) begin
        n_errors++;
        $error("T5 слово %0d: 0x%08h", i, rx_q[i]);
        break;
      end
    axi_read(5'h18, v); chk("DROPPED після flush", v, 32'd3);   // clr_stats не викликали
    axi_write(5'h00, 32'h5);                                    // clr_stats
    axi_read(5'h10, v); chk("PUSHED після clr", v, 32'd0);

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "РЕЗУЛЬТАТ: PASS" : "РЕЗУЛЬТАТ: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  initial begin
    #(CLK_P * 200000);
    $error("Watchdog: тест завис");
    $finish;
  end

endmodule
