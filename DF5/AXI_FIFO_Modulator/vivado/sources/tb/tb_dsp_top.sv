//==============================================================================
// tb_dsp_top -- тестбенч dsp_regs (увесь DSP у залізі).
//
//   T1  ID обох банків, значення після скиду
//   T2  генератор -> демодулятор: N пакетів, кожен з CRC OK і байтами
//       "DF5 PKTnn " + (17*nn + 7*i + 0x42), як у tools/iqgen.py
//   T4  генератор + захоплення з очікуванням кінця пакета: 2 пакети по ~468 біт
//   T5  live: спектр усього потоку генератора по колу, рядки додаються, пакети видно
//   T3  (після T4, як на платі: файл після захоплення з генератора) sim.iq через
//       S_AXIS + захоплення без очікування пакета: демодулятор декодує обидва
//       пакети, захоплення доходить до DONE; дамп колонок, спектра й бітів ->
//       dsp_capture_dump.txt, його звіряє з моделлю tools/check_dsp_capture.py
//
// Шляхи: +IQ_FILE=...  +DUMP_FILE=...
//==============================================================================
`timescale 1ns/1ps

module tb_dsp_top;

  localparam int  AW    = 16;
  localparam time CLK_P = 10ns;

  string iq_file   = "sim.iq";
  string dump_file = "dsp_capture_dump.txt";

  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  logic [AW-1:0] awaddr, araddr;
  logic          awvalid, awready, wvalid, wready, bvalid, bready;
  logic          arvalid, arready, rvalid, rready;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          s_tvalid, s_tready;
  logic [31:0]   s_tdata;
  logic          irq;

  dsp_regs #(.C_S_AXI_ADDR_WIDTH(AW)) dut (
    .s_axi_aclk (aclk), .s_axi_aresetn (arstn),
    .s_axi_awaddr (awaddr), .s_axi_awprot (3'b000), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
    .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
    .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
    .s_axi_araddr (araddr), .s_axi_arprot (3'b000), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
    .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
    .s_axis_tvalid (s_tvalid), .s_axis_tready (s_tready), .s_axis_tdata (s_tdata),
    .irq (irq)
  );

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
      begin
        awaddr <= addr; awvalid <= 1'b1;
        do @(posedge aclk); while (!awready);
        awvalid <= 1'b0;
      end
      begin
        wdata <= data; wstrb <= '1; wvalid <= 1'b1;
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

  task automatic axi_read(input logic [AW-1:0] addr, output logic [31:0] data);
    fork
      begin
        araddr <= addr; arvalid <= 1'b1;
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
  // очікувані байти пакета генератора
  //==========================================================================
  function automatic string gen_payload_hex(input int k);
    string s = "", tag;
    byte b;
    tag = $sformatf("DF5 PKT%02d ", k % 100);
    for (int i = 0; i < 46; i++) begin
      if (i < 10) b = tag[i];
      else        b = byte'(((k % 100) * 17 + i * 7 + 'h42) & 'hFF);
      s = {s, $sformatf("%02x", b)};
    end
    return s;
  endfunction

  // байти пакета з пам'яті демодулятора (0x100..)
  task automatic read_packet(output string hex, output logic crc_ok, output int kind);
    logic [31:0] flags, nb, w;
    axi_read(16'h060, flags);
    axi_read(16'h080, nb);
    kind   = flags[7:6];
    crc_ok = flags[3];
    hex = "";
    for (int i = 0; i < nb; i += 4) begin
      axi_read(16'h100 + 16'(i), w);
      for (int b = 0; b < 4 && i + b < nb; b++) hex = {hex, $sformatf("%02x", w[8*b +: 8])};
    end
    axi_write(16'h000, 32'h0000_0009);           // enable + ack_result
  endtask

  //==========================================================================
  logic [31:0] v;
  int          fd, rc, n_samples;
  logic [7:0]  iq_bytes [];
  string       hex;
  logic        crc_ok;
  int          kind, got, crc_ok_n;

  task automatic wait_capture_done(input int max_cycles);
    int n = 0;
    do begin
      repeat (1000) @(posedge aclk);
      n += 1000;
      axi_read(16'h304, v);
    end while (v[2:0] != 3'd4 && n < max_cycles);
  endtask

  task automatic dump_capture();
    int f;
    logic [31:0] w;
    f = $fopen(dump_file, "w");
    axi_read(16'h31C, w); $fdisplay(f, "T0 %0d", w);
    axi_read(16'h30C, w); $fdisplay(f, "LEN %0d", w);
    axi_read(16'h314, w); $fdisplay(f, "WF_SHIFT %0d", w[4:0]);
    axi_read(16'h348, w); $fdisplay(f, "BIN0 %0d", w[7:0]);
    axi_read(16'h304, w); $fdisplay(f, "STATUS %08h", w);
    for (int p = 0; p < 2; p++) begin
      logic [31:0] s, e, fb, nb;
      axi_read(16'h320 + 16'(16*p), s);
      axi_read(16'h324 + 16'(16*p), e);
      axi_read(16'h328 + 16'(16*p), fb);
      axi_read(16'h32C + 16'(16*p), nb);
      $fwrite(f, "PKT %0d %0d %0d %0d %0d", p, s, e, fb, nb);
      for (int k = 0; k < 16; k++) begin
        axi_read(16'h400 + 16'(64*p + 4*k), w);
        $fwrite(f, " %08h", w);
      end
      $fwrite(f, "\n");
    end
    for (int c = 0; c < 384; c++) begin
      axi_read(16'h800 + 16'(4*c), w);
      $fdisplay(f, "RAW %0d %08h", c, w);
    end
    for (int k = 0; k < 40 * 32; k++) begin
      axi_read(16'h8000 + 16'(4*k), w);
      $fdisplay(f, "WF %0d %08h", k, w);
    end
    $fclose(f);
    $display("дамп захоплення -> %s", dump_file);
  endtask

  initial begin
    awvalid <= 0; wvalid <= 0; bready <= 0; arvalid <= 0; rready <= 0;
    awaddr <= '0; araddr <= '0; wdata <= '0; wstrb <= '0;
    s_tvalid <= 0; s_tdata <= '0;
    void'($value$plusargs("IQ_FILE=%s", iq_file));
    void'($value$plusargs("DUMP_FILE=%s", dump_file));

    arstn = 1'b0;
    repeat (5) @(posedge aclk);
    arstn = 1'b1;
    repeat (20) @(posedge aclk);

    //------------------------------------------------------------------- T1
    $display("\n=== T1: ID, значення після скиду ===");
    axi_read(16'h0FC, v); chk("ID демодулятора", v, 32'h4453_4D01);
    axi_read(16'h2FC, v); chk("ID dsp", v, 32'h4453_5001);
    axi_read(16'h200, v); chk("SRC_CTRL", v, 32'h1);
    axi_read(16'h30C, v); chk("CAP_LEN", v, 32'd327680);
    axi_read(16'h304, v); chk("CAP_STATUS", v & 32'h7, 32'h0);

    //------------------------------------------------------------------- T2
    $display("\n=== T2: генератор -> демодулятор ===");
    axi_write(16'h204, 32'hFFFF_FFFF);           // максимальний темп
    axi_write(16'h200, 32'h3);                   // генератор, увімкнено
    axi_write(16'h000, 32'h1);                   // демодулятор
    got = 0; crc_ok_n = 0;
    fork
      begin
        while (got < 3) begin
          @(posedge aclk);
          if (irq) begin
            read_packet(hex, crc_ok, kind);
            $display("[PKT] kind=%0d crc_ok=%0b %s...", kind, crc_ok, hex.substr(0, 39));
            if (kind == 0) begin
              n_checks++;
              if (hex != {gen_payload_hex(got), hex.substr(92, 95)} || !crc_ok) begin
                n_errors++;
                $error("пакет %0d: очікувалось %s + CRC OK", got, gen_payload_hex(got));
              end
              else begin
                crc_ok_n++;
                $display("      пакет %0d збігається, CRC OK: PASS", got);
              end
              got++;
            end
          end
        end
      end
      begin
        repeat (8_000_000) @(posedge aclk);
        $error("T2: за 8 млн тактів прийшло лише %0d пакетів", got);
        n_errors++;
      end
    join_any
    disable fork;
    axi_read(16'h220, v); $display("GEN_PKTS = %0d", v);
    axi_write(16'h200, 32'h0);                   // генератор вимкнено, джерело = S_AXIS

    //------------------------------------------------------------------- T4
    $display("\n=== T4: генератор + захоплення з очікуванням пакета ===");
    axi_write(16'h000, 32'h0000_0006);
    axi_write(16'h000, 32'h0000_0001);
    axi_write(16'h314, 32'h0000_0005);           // чекати кінця пакета
    axi_write(16'h308, 32'd16384);
    axi_write(16'h300, 32'h1);                   // arm
    axi_write(16'h200, 32'h3);                   // генератор
    fork
      forever begin
        @(posedge aclk);
        if (irq) axi_write(16'h000, 32'h0000_0009);
      end
      wait_capture_done(20_000_000);
    join_any
    disable fork;
    axi_read(16'h304, v);
    chk("T4 захоплення DONE", v[2:0], 32'd4);
    chk("T4 пакетів", v[5:4], 32'd2);
    for (int p = 0; p < 2; p++) begin
      logic [31:0] s, e, nb;
      axi_read(16'h320 + 16'(16*p), s);
      axi_read(16'h324 + 16'(16*p), e);
      axi_read(16'h32C + 16'(16*p), nb);
      $display("пакет %0d: відліки %0d..%0d, %0d біт", p, s, e, nb);
      n_checks++;
      // 464 біти кадру + кілька після нього: детектор тримає burst ще ~100
      // децимованих відліків (затримка hang), слайсер весь цей час видає біти
      if (nb < 464 || nb > 490) begin
        n_errors++;
        $error("T4: пакет %0d має %0d біт, очікувалось 464..490", p, nb);
      end
    end

    //------------------------------------------------------------------- T3
    $display("\n=== T3: sim.iq + захоплення ===");
    fd = $fopen(iq_file, "rb");
    if (fd == 0) begin
      $error("не відкрився %s", iq_file);
      $finish;
    end
    rc = $fseek(fd, 0, 2);
    n_samples = $ftell(fd) / 4;
    rc = $fseek(fd, 0, 0);
    iq_bytes = new[n_samples * 4];
    rc = $fread(iq_bytes, fd);
    $fclose(fd);
    $display("%s: %0d відліків", iq_file, n_samples);

    axi_write(16'h200, 32'h0);                   // джерело = S_AXIS (генератор вимкнено)
    // демодулятор із чистого стану: soft reset, лічильники
    axi_write(16'h000, 32'h0000_0006);
    axi_write(16'h000, 32'h0000_0001);
    axi_write(16'h308, 32'd16384);               // warmup
    axi_write(16'h314, 32'h0000_0105);           // nowait, 32 блоки на рядок
    axi_write(16'h348, 32'd130);                 // вікно спектра навколо каналу, як у прошивці
    // потік стоїть, поки FFT зайнятий: запускаємо після arm
    axi_write(16'h300, 32'h1);                   // arm

    got = 0;
    fork
      begin
        for (int k = 0; k < n_samples; k++) begin
          s_tdata  <= {iq_bytes[4*k+3], iq_bytes[4*k+2], iq_bytes[4*k+1], iq_bytes[4*k+0]};
          s_tvalid <= 1'b1;
          do @(posedge aclk); while (!s_tready);
          s_tvalid <= 1'b0;
          if ($urandom_range(0, 15) == 0) repeat ($urandom_range(1, 3)) @(posedge aclk);
        end
        repeat (5000) @(posedge aclk);
      end
      begin
        forever begin
          @(posedge aclk);
          if (irq) begin
            read_packet(hex, crc_ok, kind);
            $display("[PKT] kind=%0d crc_ok=%0b %s...", kind, crc_ok, hex.substr(0, 39));
            if (kind == 0 && crc_ok) got++;
          end
        end
      end
    join_any
    disable fork;
    n_checks++;
    if (got != 2) begin
      n_errors++;
      $error("T3: декодовано %0d пакетів із CRC OK, очікувалось 2", got);
    end
    else $display("T3: 2/2 пакети з CRC OK: PASS");

    axi_read(16'h304, v);
    $display("CAP_STATUS = %08h (стан %0d, рядків %0d)", v, v[2:0], v[15:8]);
    chk("захоплення DONE", v[2:0], 32'd4);
    chk("40 рядків waterfall", v[15:8], 32'd40);
    dump_capture();

    //------------------------------------------------------------------- T5
    $display("\n=== T5: live-спектр від генератора ===");
    begin
      logic [31:0] r0, r1, w;
      int peak_hi = 0, peak_lo = 255;
      axi_write(16'h300, 32'h2);                 // abort захоплення
      axi_write(16'h314, 32'h0000_0005);         // рядок = 32 блоки
      axi_write(16'h340, 32'h1);                 // live
      axi_write(16'h200, 32'h3);                 // генератор
      axi_read(16'h344, r0);
      // макс. темп генератора: ~10 тактів на відлік -> 3 млн тактів ~ 300 тис. відліків
      // ~ 2 періоди пакета ~ 36 рядків по 32 блоки
      repeat (3_000_000) @(posedge aclk);
      axi_read(16'h344, r1);
      $display("SPEC_ROWS %0d -> %0d", r0, r1);
      n_checks++;
      if (r1 < r0 + 30) begin
        n_errors++;
        $error("T5: за 3 млн тактів додалось лише %0d рядків", r1 - r0);
      end
      // рядки, додані в live: пік кожного; серед них мають бути і шум, і пакет
      for (int r = 1; r <= int'(r1 - r0); r++) begin
        int pk = 0;
        for (int k = 0; k < 32; k++) begin
          axi_read(16'h8000 + 16'(128 * ((r1 - r) % 256) + 4 * k), w);
          for (int l = 0; l < 4; l++) if (w[8*l +: 8] > pk) pk = w[8*l +: 8];
        end
        if (pk > peak_hi) peak_hi = pk;
        if (pk < peak_lo) peak_lo = pk;
      end
      $display("пік рядків: шум %0d, пакет %0d", peak_lo, peak_hi);
      n_checks++;
      if (peak_hi < peak_lo + 40) begin
        n_errors++;
        $error("T5: у live-рядках не видно пакета (шум %0d, макс %0d)", peak_lo, peak_hi);
      end
      axi_read(16'h304, w);
      chk("T5 захоплення не чіпали (idle)", w[2:0], 32'd0);
    end

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  initial begin
    #(CLK_P * 60_000_000);
    $error("Watchdog: тест завис");
    $finish;
  end

endmodule
