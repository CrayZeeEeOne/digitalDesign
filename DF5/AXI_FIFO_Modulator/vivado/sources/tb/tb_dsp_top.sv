//==============================================================================
// tb_dsp_top -- тестбенч dsp_regs (увесь DSP у залізі) на справжньому записі.
//
// hop.iq -- три пакети Alarm-Beacon із capture_300MB.iq (tools/make_hop_iq.py),
// на каналах 866.7, 867.1 і 867.3 МГц, з шумом навколо. Налаштування -- як у
// прошивці (hal/dsp_rtl.c): 15 каналів, вхід x64, live-спектр, захоплення по
// пакету.
//
//   T1  ID, значення після скиду
//   T2  hop.iq через S_AXIS: dsp_hop знаходить кожен пакет і перестроює
//       демодулятор; 3 пакети з CRC OK, байти й канали як у hop.iq.json
//   T3  захоплення, запущене першим пакетом: DONE, пакет усередині;
//       дамп колонок, рядків waterfall і бітів -> dsp_capture_dump.txt, його
//       звіряє tools/check_dsp_capture.py біт у біт
//
// Шляхи: +IQ_FILE=...  +DUMP_FILE=...
//==============================================================================
`timescale 1ns/1ps

module tb_dsp_top;

  localparam int  AW    = 16;
  localparam time CLK_P = 10ns;

  localparam real FS = 4.5e6;
  localparam real LO = 867.4e6;
  localparam real CH_MHZ [0:14] = '{865.3, 865.5, 865.9, 866.1, 866.5, 866.7, 867.1, 867.3,
                                    867.7, 867.9, 868.1, 868.3, 868.9, 869.1, 869.5};
  localparam int  GAIN     = 6;
  localparam int  WF_SHIFT = 6;

  // очікувані пакети (hop.iq.json): канал і 16 байт після sync, знебілені
  localparam int    EXP_N = 3;
  localparam int    EXP_CH  [0:2] = '{5, 6, 7};
  localparam string EXP_HEX [0:2] = '{"0d0000000000e90d1fe907040066f61a",
                                      "0d0000000000ea0d1fea07040066d0bd",
                                      "0d0000000000eb0d1feb070400663d3f"};

  string iq_file   = "hop.iq";
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

  // байти пакета з пам'яті демодулятора (0x100..) і канал (HOP_STATUS[11:8])
  task automatic read_packet(output string hex, output logic crc_ok, output int kind, output int ch);
    logic [31:0] flags, nb, w;
    axi_read(16'h060, flags);
    axi_read(16'h080, nb);
    axi_read(16'h384, w);
    ch     = w[11:8];
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
  int          kind, ch, got;

  task automatic dump_capture();
    int f;
    logic [31:0] w, rows;
    f = $fopen(dump_file, "w");
    axi_read(16'h31C, w); $fdisplay(f, "T0 %0d", w);
    axi_read(16'h30C, w); $fdisplay(f, "LEN %0d", w);
    axi_read(16'h314, w); $fdisplay(f, "WF_SHIFT %0d", w[4:0]);
    axi_read(16'h348, w); $fdisplay(f, "BIN0 %0d", w[7:0]);
    axi_read(16'h200, w); $fdisplay(f, "GAIN %0d", w[3:0]);
    axi_read(16'h344, rows); $fdisplay(f, "ROWS %0d", rows);
    axi_read(16'h304, w); $fdisplay(f, "STATUS %08h", w);
    for (int p = 0; p < 2; p++) begin
      logic [31:0] s, e, fb, nb;
      axi_read(16'h320 + 16'(16*p), s);
      axi_read(16'h324 + 16'(16*p), e);
      axi_read(16'h328 + 16'(16*p), fb);
      axi_read(16'h32C + 16'(16*p), nb);
      if (nb == 0) continue;
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
    for (int k = 0; k < ((rows > 256) ? 256 : int'(rows)) * 32; k++) begin
      axi_read(16'h8000 + 16'(4*k), w);
      $fdisplay(f, "WF %0d %08h", k, w);
    end
    $fclose(f);
    $display("дамп захоплення -> %s", dump_file);
  endtask

  // конфігурація, як у прошивці
  task automatic configure();
    // канали: 3 біни FFT навколо кожного, NCO переносить канал у 0 Гц
    for (int b = 0; b < 256; b++) axi_write(16'h38C, {20'd0, 4'd15, 8'(b)});
    for (int c = 0; c < 15; c++) begin
      real ofs = CH_MHZ[c] * 1.0e6 - LO;
      int  bc  = int'($floor(ofs / FS * 256.0 + 0.5));
      longint inc = longint'($floor(-ofs / FS * 4294967296.0 + 0.5));
      for (int d = -1; d <= 1; d++) axi_write(16'h38C, {20'd0, 4'(c), 8'(bc + d)});
      axi_write(16'h390 + 16'(4*c), 32'(inc));
    end
    axi_write(16'h200, 32'(GAIN));
    axi_write(16'h380, {16'd8192, 4'd2, 4'd4, 4'd5, 4'd1});   // hold, confirm, noise, thr, en
    axi_write(16'h348, 32'd128);                // уся смуга
    axi_write(16'h340, 32'h1);                  // live-спектр
    axi_write(16'h308, 32'd1);                  // warmup
    axi_write(16'h30C, 32'd98304);
    axi_write(16'h310, 32'd256);                // 98304 / 384, залишок 0
    axi_write(16'h314, 32'h200 | WF_SHIFT);     // чекати пакета від dsp_hop
    axi_write(16'h000, 32'h1);                  // демодулятор
    axi_write(16'h300, 32'h1);                  // arm
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
    axi_read(16'h2FC, v); chk("ID dsp", v, 32'h4453_5002);
    axi_read(16'h204, v); chk("DL_LEN", v, 32'd4096);
    axi_read(16'h024, v); chk("CRC_RESIDUE + PN9", v, 32'h0001_1D0F);
    axi_read(16'h01C, v); chk("PKT_LEN", v, 32'd16);
    axi_read(16'h304, v); chk("CAP_STATUS", v & 32'h7, 32'h0);

    //------------------------------------------------------------------- T2
    $display("\n=== T2: hop.iq -> пошук каналу -> демодулятор ===");
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

    configure();

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
            read_packet(hex, crc_ok, kind, ch);
            $display("[PKT] kind=%0d crc_ok=%0b канал %0d (%.1f МГц) %s", kind, crc_ok, ch, CH_MHZ[ch], hex);
            if (kind == 0) begin
              n_checks++;
              if (got >= EXP_N || hex != EXP_HEX[got] || ch != EXP_CH[got] || !crc_ok) begin
                n_errors++;
                $error("пакет %0d: очікувалось %s на каналі %0d з CRC OK", got,
                       (got < EXP_N) ? EXP_HEX[got] : "-", (got < EXP_N) ? EXP_CH[got] : -1);
              end
              else $display("      пакет %0d: байти, канал і CRC збігаються: PASS", got);
              got++;
            end
          end
        end
      end
    join_any
    disable fork;
    n_checks++;
    if (got != EXP_N) begin
      n_errors++;
      $error("T2: декодовано %0d пакетів, очікувалось %0d", got, EXP_N);
    end
    else $display("T2: %0d/%0d пакетів: PASS", got, EXP_N);
    axi_read(16'h388, v);
    $display("HOP: виявлень %0d, без пакета %0d", v[15:0], v[31:16]);
    chk("HOP виявлень", v, 32'(EXP_N));

    //------------------------------------------------------------------- T3
    $display("\n=== T3: захоплення по першому пакету ===");
    axi_read(16'h304, v);
    $display("CAP_STATUS = %08h (стан %0d, пакетів %0d)", v, v[2:0], v[5:4]);
    chk("захоплення DONE", v[2:0], 32'd4);
    chk("пакет у захопленні", v[5:4], 32'd1);
    axi_read(16'h344, v);
    $display("SPEC_ROWS = %0d (%0d відліків / %0d)", v, n_samples, 256 << WF_SHIFT);
    chk("рядків waterfall", v, 32'(n_samples / (256 << WF_SHIFT)));
    dump_capture();

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  // траса виявлень dsp_hop (для налагодження)
  always @(posedge aclk) if (dut.u_hop.trig)
    $display("[HOP] вхід %0d: канал %0d, сума %0d, шум %0d", dut.in_count, dut.u_hop.best,
             dut.u_hop.best_pow, dut.u_hop.noise[dut.u_hop.best]);

  initial begin
    #(CLK_P * 60_000_000);
    $error("Watchdog: тест завис");
    $finish;
  end

endmodule
