//==============================================================================
// tb_sd_host -- sd_host (нативний SD, 4 біти) з моделлю картки sd_card_model.
//
//   T1  ініціалізація, як у прошивці: 400 кГц, CMD0, CMD8, ACMD41, CMD2, CMD3,
//       CMD9, CMD7, ACMD6 (4 біти), далі 25 МГц
//   T2  CMD17: блок у буфер, байти збігаються з пам'яттю картки
//   T3  CMD24: блок із буфера на картку (CRC status OK), CMD17 -- назад
//   T4  потік FMT8 без темпу, повільний споживач (FIFO 256 слів -> тактова
//       зупиняється між блоками): 24 блоки = 12288 відліків, жоден не втрачено
//   T5  потік FMT8 з темпом 4.5 МВід/с: відліки йдуть рівно в цьому темпі
//       (FMT16 потребує 18 МБ/с, а шина на 25 МГц дає лише 12.5: ~3 МВід/с)
//
// Перевірки: помилки CRC/тайм-аутів у STATUS, помилки CRC, побачені карткою.
//==============================================================================
`timescale 1ns/1ps

module tb_sd_host;

  localparam int  AW    = 12;
  localparam time CLK_P = 10ns;

  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  logic [AW-1:0] awaddr, araddr;
  logic          awvalid, awready, wvalid, wready, bvalid, bready;
  logic          arvalid, arready, rvalid, rready;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          m_tvalid, m_tready;
  logic [31:0]   m_tdata;

  wire        sd_clk, sd_cmd_o, sd_cmd_oe, sd_dat_oe;
  wire [3:0]  sd_dat_o;
  tri1        sd_cmd;                     // підтяжки на платі
  tri1 [3:0]  sd_dat;

  assign sd_cmd = sd_cmd_oe ? sd_cmd_o : 1'bz;
  assign sd_dat = sd_dat_oe ? sd_dat_o : 4'bzzzz;

  sd_host #(.C_S_AXI_ADDR_WIDTH(AW), .FIFO_DEPTH(256)) dut (
    .s_axi_aclk (aclk), .s_axi_aresetn (arstn),
    .s_axi_awaddr (awaddr), .s_axi_awprot (3'b000), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arprot (3'b000), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .m_axis_tvalid (m_tvalid), .m_axis_tready (m_tready), .m_axis_tdata (m_tdata),
    .sd_clk, .sd_cmd_o, .sd_cmd_oe, .sd_cmd_i (sd_cmd),
    .sd_dat_o, .sd_dat_oe, .sd_dat_i (sd_dat)
  );

  sd_card_model #(.BLOCKS(64)) card (.sd_clk, .cmd (sd_cmd), .dat (sd_dat));

  //==========================================================================
  int n_checks = 0, n_errors = 0;

  task automatic chk(input string name, input logic [31:0] got, exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      $error("%s: очікувалось 0x%08h, отримано 0x%08h", name, exp, got);
    end
    else $display("%s: PASS (0x%08h)", name, got);
  endtask

  task automatic axi_write(input logic [AW-1:0] addr, input logic [31:0] data);
    fork
      begin awaddr <= addr; awvalid <= 1'b1; do @(posedge aclk); while (!awready); awvalid <= 1'b0; end
      begin wdata <= data; wstrb <= '1; wvalid <= 1'b1; do @(posedge aclk); while (!wready); wvalid <= 1'b0; end
      begin bready <= 1'b1; do @(posedge aclk); while (!bvalid); bready <= 1'b0; end
    join
  endtask

  task automatic axi_read(input logic [AW-1:0] addr, output logic [31:0] data);
    fork
      begin araddr <= addr; arvalid <= 1'b1; do @(posedge aclk); while (!arready); arvalid <= 1'b0; end
      begin rready <= 1'b1; do @(posedge aclk); while (!rvalid); data = rdata; rready <= 1'b0; end
    join
  endtask

  // команда: idx, arg, відповідь (0/1/2), busy, crc, дані (0/1/2); чекає кінця
  task automatic sd_cmd_run(input int idx, input logic [31:0] arg, input int rsp, input bit bw,
                            input bit crc, input int data, output logic [31:0] st);
    axi_write(12'h008, arg);
    axi_write(12'h00C, (data << 10) | (crc << 9) | (bw << 8) | (rsp << 6) | idx);
    do axi_read(12'h004, st); while (st[1:0] != 2'b00);
  endtask

  logic [31:0] v, st, r0;
  int          got;

  initial begin
    awvalid <= 0; wvalid <= 0; bready <= 0; arvalid <= 0; rready <= 0;
    awaddr <= '0; araddr <= '0; wdata <= '0; wstrb <= '0;
    m_tready <= 1'b0;
    for (int i = 0; i < 64 * 512; i++) card.mem[i] = 8'((i * 37 + (i >> 9) * 11) ^ (i >> 3));

    arstn = 1'b0;
    repeat (5) @(posedge aclk);
    arstn = 1'b1;
    repeat (20) @(posedge aclk);

    //------------------------------------------------------------------- T1
    $display("\n=== T1: ініціалізація ===");
    axi_read(12'h03C, v); chk("ID", v, 32'h5344_0001);
    axi_write(12'h000, 32'h0000_1000 | (2 << 8) | 124);         // 400 кГц, вільна тактова
    repeat (80 * 250) @(posedge aclk);                            // >= 74 такти
    axi_write(12'h000, (2 << 8) | 124);
    sd_cmd_run(0, 0, 0, 0, 0, 0, st);
    sd_cmd_run(8, 32'h1AA, 1, 0, 1, 0, st);
    axi_read(12'h010, r0); chk("CMD8 луна", r0 & 32'hFFF, 32'h1AA);
    chk("CMD8 без помилок", st & 32'h1F0, 0);
    do begin
      sd_cmd_run(55, 0, 1, 0, 1, 0, st);
      sd_cmd_run(41, 32'h40FF_8000, 1, 0, 0, 0, st);
      axi_read(12'h010, r0);
    end while (!r0[31]);
    chk("ACMD41: SDHC", r0[30], 1);
    sd_cmd_run(2, 0, 2, 0, 0, 0, st);
    sd_cmd_run(3, 0, 1, 0, 1, 0, st);
    axi_read(12'h010, r0); chk("RCA", r0[31:16], 32'h1234);
    sd_cmd_run(9, 32'h1234_0000, 2, 0, 0, 0, st);
    axi_read(12'h01C, v); chk("CSD v2 (біти 127:96)", v, 32'h400E_0032);
    sd_cmd_run(7, 32'h1234_0000, 1, 1, 1, 0, st);
    chk("CMD7 (R1b)", st & 32'h1F0, 0);
    sd_cmd_run(55, 32'h1234_0000, 1, 0, 1, 0, st);
    sd_cmd_run(6, 2, 1, 0, 1, 0, st);
    chk("ACMD6: 4 біти", card.bus4, 1);
    axi_write(12'h000, (2 << 8) | 1);                            // 25 МГц, SDLY 2

    //------------------------------------------------------------------- T2
    $display("\n=== T2: CMD17 ===");
    sd_cmd_run(17, 5, 1, 0, 1, 1, st);
    chk("CMD17 без помилок", st & 32'h1F0, 0);
    got = 0;
    for (int w = 0; w < 128; w++) begin
      axi_read(12'h200 + 12'(4 * w), v);
      for (int b = 0; b < 4; b++) if (v[8*b +: 8] != card.mem[5 * 512 + 4 * w + b]) got++;
    end
    chk("CMD17: байтів не збіглось", got, 0);

    //------------------------------------------------------------------- T3
    $display("\n=== T3: CMD24 + CMD17 ===");
    for (int w = 0; w < 128; w++) axi_write(12'h200 + 12'(4 * w), 32'hA5000000 ^ (w * 32'h01010101) ^ 32'h3C);
    sd_cmd_run(24, 7, 1, 0, 1, 2, st);
    chk("CMD24 без помилок (CRC status 010)", st & 32'h1F0, 0);
    chk("картка: CRC даних запису", card.err_dat_crc, 0);
    for (int w = 0; w < 128; w++) axi_write(12'h200 + 12'(4 * w), 0);
    sd_cmd_run(17, 7, 1, 0, 1, 1, st);
    got = 0;
    for (int w = 0; w < 128; w++) begin
      axi_read(12'h200 + 12'(4 * w), v);
      if (v != (32'hA5000000 ^ (w * 32'h01010101) ^ 32'h3C)) got++;
    end
    chk("записане прочитано назад: слів не збіглось", got, 0);

    //------------------------------------------------------------------- T4
    $display("\n=== T4: потік FMT8, повільний споживач ===");
    axi_write(12'h000, 32'h0001_0000 | (2 << 8) | 1);            // FMT8
    axi_write(12'h034, 0);                                        // без темпу
    axi_write(12'h028, 32'h4);                                    // скинути FIFO
    axi_write(12'h020, 10);
    axi_write(12'h024, 24);
    axi_write(12'h028, 32'h1);
    got = 0;
    fork
      begin : sink
        for (int k = 0; k < 24 * 256; k++) begin
          int a = 10 * 512 + 2 * k;
          logic [31:0] exp = {{8{card.mem[a+1][7]}}, card.mem[a+1], {8{card.mem[a][7]}}, card.mem[a]};
          repeat ($urandom_range(0, 40)) @(posedge aclk);       // повільно: FIFO наповнюється
          m_tready <= 1'b1;
          do @(posedge aclk); while (!m_tvalid);
          m_tready <= 1'b0;
          if (m_tdata != exp) begin
            if (got < 5) $error("відлік %0d: 0x%08h, очікувалось 0x%08h", k, m_tdata, exp);
            got++;
          end
        end
      end
      begin repeat (20_000_000) @(posedge aclk); $error("T4: тайм-аут"); end
    join_any
    disable fork;
    chk("T4: відліків не збіглось", got, 0);
    do axi_read(12'h004, st); while (st[2]);
    chk("T4: STATUS без помилок", st & 32'h1F0, 0);
    axi_read(12'h02C, v); chk("T4: блоків", v, 24);
    axi_read(12'h040, v); chk("T4: відліків видано", v, 24 * 256);

    //------------------------------------------------------------------- T5
    $display("\n=== T5: потік FMT8, темп 4.5 МВід/с ===");
    axi_write(12'h000, 32'h0001_0000 | (2 << 8) | 1);            // FMT8
    axi_write(12'h034, 32'd193273528);                           // 2^32 * 4.5 / 100
    axi_write(12'h028, 32'h4);
    axi_write(12'h040, 0);
    axi_write(12'h038, 0);
    axi_write(12'h020, 20);
    axi_write(12'h024, 4);
    m_tready <= 1'b1;
    axi_write(12'h028, 32'h1);
    begin
      time t0, t1;
      int  n = 0;
      got = 0;
      while (n < 4 * 256) begin
        @(posedge aclk);
        if (m_tvalid && m_tready) begin
          int a = 20 * 512 + 2 * n;
          if (m_tdata != {{8{card.mem[a+1][7]}}, card.mem[a+1], {8{card.mem[a][7]}}, card.mem[a]}) got++;
          if (n == 100) t0 = $time;
          if (n == 400) t1 = $time;
          n++;
        end
      end
      m_tready <= 1'b0;
      chk("T5: відліків не збіглось", got, 0);
      $display("T5: 300 відліків за %0d нс -> %.3f МВід/с", t1 - t0, 300.0e3 / (t1 - t0));
      n_checks++;
      if ((t1 - t0) < 66_000 || (t1 - t0) > 67_400) begin
        n_errors++;
        $error("T5: темп не 4.5 МВід/с");
      end
    end
    do axi_read(12'h004, st); while (st[2]);
    chk("T5: STATUS без помилок", st & 32'h1F0, 0);
    chk("картка: помилок CRC команд", card.err_cmd_crc, 0);

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  initial begin
    #(CLK_P * 30_000_000);
    $error("Watchdog: тест завис");
    $display("ks %0d cs %0d ds %0d done %0d left %0d level %0d out %0d pend %0b have %0b tvalid %0b",
             dut.ks, dut.cs, dut.ds, dut.d_done, dut.d_left, dut.f_level, dut.out_cnt, dut.pend, dut.u_have, m_tvalid);
    $finish;
  end

endmodule
