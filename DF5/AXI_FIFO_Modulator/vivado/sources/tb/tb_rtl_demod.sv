//==============================================================================
// tb_rtl_demod -- тестбенч демодулятора на записаному I/Q.
//
// Читає sim.iq (int16 I/Q LE), конфігурацію й очікувані пакети з
// sim.expect.txt (їх пише tools/demod_model.py), жене відліки в S_AXIS з
// випадковими паузами, опитує RESULT_VALID через AXI4-Lite і звіряє
// декодовані байти та CRC з очікуваними. Додатково порівнює dphi кожного
// децимованого відліку з трасою Python-моделі (sim.trace.txt) -- так видно,
// що RTL і модель збігаються біт у біт.
//
// Шляхи можна перевизначити: +IQ_FILE=... +EXPECT_FILE=... +TRACE_FILE=...
// (sim.tcl робить це автоматично).
//==============================================================================
`timescale 1ns/1ps

module tb_rtl_demod;

  localparam int  ADDR_BW = 9;
  localparam time CLK_P   = 10ns;

  string iq_file     = "../../../../sources/sim_data/sim.iq";
  string expect_file = "../../../../sources/sim_data/sim.expect.txt";
  string trace_file  = "../../../../sources/sim_data/sim.trace.txt";

  //==========================================================================
  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  logic [ADDR_BW-1:0] awaddr, araddr;
  logic               awvalid, awready, wvalid, wready, bvalid, bready;
  logic               arvalid, arready, rvalid, rready;
  logic [31:0]        wdata, rdata;
  logic [3:0]         wstrb;
  logic [1:0]         bresp, rresp;

  logic        s_tvalid, s_tready;
  logic [31:0] s_tdata;
  logic        irq;

  rtl_demod_regs #(.C_S_AXI_ADDR_WIDTH(ADDR_BW)) dut (
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
    else
      $display("%s: PASS (0x%08h)", name, got);
  endtask

  task automatic axi_write(input logic [ADDR_BW-1:0] addr, input logic [31:0] data);
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

  task automatic axi_read(input logic [ADDR_BW-1:0] addr, output logic [31:0] data);
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
  // CORDIC: окрема перевірка проти $atan2
  //==========================================================================
  logic               c_valid_in, c_valid_out;
  logic signed [17:0] c_x, c_y;
  logic signed [15:0] c_ang;
  logic [31:0]        c_aux_o;

  demod_cordic_atan2 #(.W(18), .ITER(16), .AUX_W(32)) u_cordic (
    .clk (aclk), .rst (!arstn),
    .in_valid (c_valid_in), .in_x (c_x), .in_y (c_y), .in_aux (32'd0),
    .out_valid (c_valid_out), .out_angle (c_ang), .out_aux (c_aux_o)
  );

  task automatic cordic_check(input real ang_rad, input real mag);
    int exp_q15, got, err;
    c_x <= $rtoi(mag * $cos(ang_rad));
    c_y <= $rtoi(mag * $sin(ang_rad));
    c_valid_in <= 1'b1;
    @(posedge aclk);
    c_valid_in <= 1'b0;
    do @(posedge aclk); while (!c_valid_out);
    got     = c_ang;
    exp_q15 = $rtoi(ang_rad / 3.14159265358979 * 32768.0);
    err = got - exp_q15;
    if (err > 32768)  err -= 65536;
    if (err < -32768) err += 65536;
    n_checks++;
    if (err > 3 || err < -3) begin
      n_errors++;
      $error("CORDIC: кут %f рад -> очікувалось %0d, отримано %0d", ang_rad, exp_q15, got);
    end
    else
      $display("CORDIC %7.4f рад: %6d (очік. %6d, похибка %0d): PASS", ang_rad, got, exp_q15, err);
  endtask

  //==========================================================================
  // Порівняння dphi з трасою моделі
  //==========================================================================
  int trace_fd;
  int trace_n = 0, trace_mismatch = 0;
  int tr_i, tr_q, tr_dphi, tr_pavg, tr_burst;
  int first_mismatch_reported = 0;

  always @(posedge aclk) begin
    if (arstn && dut.u_core.pw_v && trace_fd != 0) begin
      if ($fscanf(trace_fd, "%d %d %d %d %d\n", tr_i, tr_q, tr_dphi, tr_pavg, tr_burst) == 5) begin
        trace_n++;
        if (dut.u_core.pw_dphi !== 16'(tr_dphi) ||
            dut.u_core.st_pavg !== 32'(tr_pavg) ||
            dut.u_core.pw_burst !== tr_burst[0]) begin
          trace_mismatch++;
          if (first_mismatch_reported < 5) begin
            first_mismatch_reported++;
            $display("[TRACE] розбіжність @dec %0d: dphi %0d/%0d  pavg %0d/%0d  burst %0d/%0d",
                     trace_n, $signed(dut.u_core.pw_dphi), tr_dphi,
                     dut.u_core.st_pavg, tr_pavg, dut.u_core.pw_burst, tr_burst);
          end
        end
      end
    end
  end

  //==========================================================================
  // Сценарій
  //==========================================================================
  logic [7:0] iq_bytes [];
  int         n_samples;
  logic [31:0] v, nco_inc, flags;
  int decim, cic_shift, bit_inc, pkt_len;
  int fd, rc;
  string line, kind;
  int exp_crc;
  string exp_hex;
  string exp_payload [$];
  int    exp_crcok  [$];
  int    got_packets = 0, got_nosync = 0;
  real   fs = 4.5e6, fs_dec;

  task automatic read_result();
    logic [31:0] r_len, r_pwr, r_peak, r_noise, r_fd, r_win, r_fsum, r_bytes, w;
    int bits, pkts, kind_i, trans, cnt, favg, dev;
    real f_res, f_sl, devhz, br, snr;
    string hex, ascii;
    axi_read(9'h060, flags);
    axi_read(9'h064, r_len);  axi_read(9'h068, r_pwr);  axi_read(9'h06C, r_peak);
    axi_read(9'h070, r_noise); axi_read(9'h074, r_fd);  axi_read(9'h078, r_win);
    axi_read(9'h07C, r_fsum); axi_read(9'h080, r_bytes);
    kind_i = flags[7:6]; pkts = flags[15:8]; bits = flags[31:16];
    trans = r_win[15:0]; cnt = r_win[31:16];
    favg = $signed(r_fd[15:0]); dev = r_fd[31:16];
    f_res = (cnt != 0) ? ($itor($signed(r_fsum)) / cnt / 32768.0 * fs_dec / 2.0) : 0.0;
    f_sl  = favg / 32768.0 * fs_dec / 2.0;
    devhz = dev / 32768.0 * fs_dec / 2.0;
    br    = (cnt != 0) ? (fs_dec * trans / cnt) : 0.0;
    snr   = (r_noise != 0 && r_pwr > r_noise) ?
            10.0 * $log10($itor(r_pwr - r_noise) / $itor(r_noise)) : 0.0;
    $display("\n[RESULT] kind=%0d burst=%0b preamble=%0b sync=%0b crc_ok=%0b inv=%0b trunc=%0b pkts=%0d bits=%0d",
             kind_i, flags[0], flags[1], flags[2], flags[3], flags[4], flags[5], pkts, bits);
    $display("         burst_len=%0d pwr=%0d peak=%0d noise=%0d", r_len, r_pwr, r_peak, r_noise);
    $display("         f_residual=%+.1f Hz (slicer %+.1f)  dev=%.0f Hz  bitrate=%.0f (%0d біт)  SNR=%.1f dB",
             f_res, f_sl, devhz, br, trans, snr);
    if (kind_i == 0) begin
      hex = "";
      ascii = "";
      for (int i = 0; i < r_bytes; i += 4) begin
        axi_read(9'h100 + 9'(i), w);
        for (int b = 0; b < 4 && i + b < r_bytes; b++) begin
          hex = {hex, $sformatf("%02x", w[8*b +: 8])};
          if (i + b < 12) ascii = {ascii, (w[8*b +: 8] >= 8'h20 && w[8*b +: 8] < 8'h7F) ?
                                           string'(w[8*b +: 8]) : "."};
        end
      end
      $display("         payload[%0d]: %s... '%s'", r_bytes, hex.substr(0, 31), ascii);
      n_checks++;
      if (got_packets < exp_payload.size()) begin
        if (hex != exp_payload[got_packets]) begin
          n_errors++;
          $error("пакет %0d: байти не збігаються з очікуваними\n  got %s\n  exp %s",
                 got_packets, hex, exp_payload[got_packets]);
        end
        else if (flags[3] != exp_crcok[got_packets]) begin
          n_errors++;
          $error("пакет %0d: CRC %0b, очікувалось %0d", got_packets, flags[3], exp_crcok[got_packets]);
        end
        else
          $display("         пакет %0d збігається з очікуваним, CRC OK: PASS", got_packets);
      end
      else begin
        n_errors++;
        $error("зайвий пакет %0d", got_packets);
      end
      got_packets++;
    end
    else begin
      got_nosync++;
    end
    axi_write(9'h000, 32'h0000_0009);      // enable + ack_result
  endtask

  initial begin
    awvalid <= 0; wvalid <= 0; bready <= 0; arvalid <= 0; rready <= 0;
    awaddr <= '0; araddr <= '0; wdata <= '0; wstrb <= '0;
    s_tvalid <= 0; s_tdata <= '0;
    c_valid_in <= 0; c_x <= '0; c_y <= '0;

    void'($value$plusargs("IQ_FILE=%s", iq_file));
    void'($value$plusargs("EXPECT_FILE=%s", expect_file));
    void'($value$plusargs("TRACE_FILE=%s", trace_file));

    arstn = 1'b0;
    repeat (5) @(posedge aclk);
    arstn = 1'b1;
    repeat (2) @(posedge aclk);

    //------------------------------------------------------------------- T0
    $display("\n=== T0: CORDIC ===");
    cordic_check( 0.0,     100000.0);
    cordic_check( 0.7854,  100000.0);
    cordic_check( 1.5708,  120000.0);
    cordic_check( 2.5,      80000.0);
    cordic_check( 3.1,     100000.0);
    cordic_check(-3.1,     100000.0);
    cordic_check(-1.0,      70000.0);
    cordic_check(-0.05,    130000.0);
    cordic_check( 0.001,   100000.0);

    //------------------------------------------------------------------- T1
    $display("\n=== T1: ID, значення після скиду ===");
    axi_read(9'h0FC, v); chk("ID", v, 32'h4453_4D01);
    axi_read(9'h008, v); chk("NCO_INC default", v, 32'h3E02_468B);
    axi_read(9'h018, v); chk("SYNC_WORD default", v, 32'h0000_91D3);
    axi_read(9'h004, v); chk("STATUS після скиду", v & 32'hFF, 32'h0);

    //------------------------------------------------------------------- T2
    $display("\n=== T2: конфігурація з %s ===", expect_file);
    fd = $fopen(expect_file, "r");
    if (fd == 0) begin
      $error("не відкрився %s", expect_file);
      $finish;
    end
    rc = $fgets(line, fd);                              // коментар
    rc = $fscanf(fd, "%h %d %d %d %d\n", nco_inc, decim, cic_shift, bit_inc, pkt_len);
    while (!$feof(fd)) begin
      rc = $fgets(line, fd);
      if (rc == 0) break;
      if (line.len() > 2 && line.substr(0, 0) == "P") begin
        rc = $sscanf(line, "P %d %s", exp_crc, exp_hex);
        exp_payload.push_back(exp_hex);
        exp_crcok.push_back(exp_crc);
      end
    end
    $fclose(fd);
    fs_dec = fs / decim;
    $display("nco_inc=0x%08h decim=%0d cic_shift=%0d bit_inc=%0d pkt_len=%0d, очікується %0d пакетів",
             nco_inc, decim, cic_shift, bit_inc, pkt_len, exp_payload.size());

    axi_write(9'h008, nco_inc);
    axi_write(9'h00C, 32'(cic_shift) << 8 | 32'(decim));
    axi_write(9'h014, 32'(bit_inc));
    axi_write(9'h01C, 32'(pkt_len));
    axi_read (9'h00C, v); chk("DECIM readback", v, 32'(cic_shift) << 8 | 32'(decim));

    //------------------------------------------------------------------- T3
    $display("\n=== T3: потік із %s ===", iq_file);
    fd = $fopen(iq_file, "rb");
    if (fd == 0) begin
      $error("не відкрився %s", iq_file);
      $finish;
    end
    // розмір файлу
    rc = $fseek(fd, 0, 2);
    n_samples = $ftell(fd) / 4;
    rc = $fseek(fd, 0, 0);
    iq_bytes = new[n_samples * 4];
    rc = $fread(iq_bytes, fd);
    $fclose(fd);
    $display("прочитано %0d байт = %0d відліків", rc, n_samples);

    trace_fd = $fopen(trace_file, "r");
    if (trace_fd == 0) $display("WARNING: траса %s недоступна, порівняння пропущено", trace_file);

    axi_write(9'h000, 32'h0000_0001);                   // enable

    fork
      // драйвер потоку з випадковими паузами
      begin
        for (int k = 0; k < n_samples; k++) begin
          s_tdata  <= {iq_bytes[4*k+3], iq_bytes[4*k+2], iq_bytes[4*k+1], iq_bytes[4*k+0]};
          s_tvalid <= 1'b1;
          do @(posedge aclk); while (!s_tready);
          s_tvalid <= 1'b0;
          if ($urandom_range(0, 7) == 0) repeat ($urandom_range(1, 3)) @(posedge aclk);
        end
        repeat (200) @(posedge aclk);
      end
      // опитування результатів
      begin
        forever begin
          @(posedge aclk);
          if (irq) read_result();
        end
      end
    join_any
    disable fork;

    repeat (100) @(posedge aclk);
    if (irq) read_result();

    //------------------------------------------------------------------- T4
    $display("\n=== T4: підсумок ===");
    axi_read(9'h03C, v); chk("IN_COUNT", v, 32'(n_samples));
    axi_read(9'h04C, v); chk("PKT_COUNT", v, 32'(exp_payload.size()));
    axi_read(9'h050, v); chk("CRC_OK_COUNT", v, 32'(exp_payload.size()));
    axi_read(9'h048, v); $display("BURST_COUNT = %0d", v);
    n_checks++;
    if (got_packets != exp_payload.size()) begin
      n_errors++;
      $error("декодовано %0d пакетів, очікувалось %0d", got_packets, exp_payload.size());
    end
    else $display("декодовано %0d/%0d пакетів: PASS", got_packets, exp_payload.size());

    if (trace_fd != 0) begin
      n_checks++;
      $display("траса: %0d децимованих відліків порівняно, розбіжностей %0d",
               trace_n, trace_mismatch);
      if (trace_mismatch != 0) begin
        n_errors++;
        $error("RTL не збігається з моделлю");
      end
      $fclose(trace_fd);
    end

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "РЕЗУЛЬТАТ: PASS" : "РЕЗУЛЬТАТ: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  initial begin
    #(CLK_P * 3_000_000);
    $error("Watchdog: тест завис");
    $finish;
  end

endmodule
