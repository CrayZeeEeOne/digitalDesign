//==============================================================================
// tb_axi_filter -- тестбенч проточного акселератора.
//
//   tb_mst --bus_in--> [ axi_slv -> axi_cl -> axi_mst ] --bus_out--> tb_slv
//
// tb_mst шле вікно одним бурстом на 9 beat'ів.
// tb_slv приймає одиничний запис результату і звіряє з референсом.
//==============================================================================
`timescale 1ns/1ps

module tb_axi_filter;

  localparam int  ADDR_BW = 32;
  localparam int  DATA_BW = 32;
  localparam int  ID_BW   = 4;
  localparam int  PIX_BW  = 8;
  localparam time CLK_P   = 10ns;

  localparam logic [1:0] F_MIN = 2'b00, F_MAX = 2'b01,
                         F_MED = 2'b10, F_SOBEL = 2'b11;

  localparam logic [ADDR_BW-1:0] SRC = 32'h0000_1000;
  localparam logic [ADDR_BW-1:0] DST = 32'h0000_2000;

  typedef logic [PIX_BW-1:0] pix_t;

  //==========================================================================
  // Такт і скид
  //==========================================================================
  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  //==========================================================================
  // Дві шини
  //==========================================================================
  axi_if #(.ADDR_BW(ADDR_BW), .DATA_BW(DATA_BW), .ID_BW(ID_BW))
    bus_in (.aclk(aclk), .arstn(arstn));

  axi_if #(.ADDR_BW(ADDR_BW), .DATA_BW(DATA_BW), .ID_BW(ID_BW))
    bus_out (.aclk(aclk), .arstn(arstn));

  //==========================================================================
  // DUT: axi_slv -> axi_cl -> axi_mst
  //==========================================================================
  logic [1:0]         cfg_select;
  logic [ADDR_BW-1:0] dst_addr;
  logic               dut_busy, dut_done, dut_err;

  pix_t win [0:8];
  logic win_valid, win_ready;
  pix_t filt_pix;

  axi_slv #(.PIX_BW(PIX_BW)) u_slv (
    .aclk        (aclk),
    .arstn       (arstn),
    .sw_bus      (bus_in.write_slv),
    .sr_bus      (bus_in.read_slv),
    .o_win       (win),
    .o_win_valid (win_valid),
    .i_win_ready (win_ready)
  );

  axi_cl #(.PIX_BW(PIX_BW)) u_cl (
    .i_win (win),
    .i_cfg (cfg_select),
    .o_pix (filt_pix)
  );

  axi_mst #(.PIX_BW(PIX_BW)) u_mst (
    .aclk        (aclk),
    .arstn       (arstn),
    .mw_bus      (bus_out.write_mst),
    .mr_bus      (bus_out.read_mst),
    .i_pix       (filt_pix),
    .i_pix_valid (win_valid),
    .o_pix_ready (win_ready),
    .dst_addr    (dst_addr),
    .busy        (dut_busy),
    .done        (dut_done),
    .err         (dut_err)
  );

  //==========================================================================
  // Референсна модель
  //==========================================================================
  function automatic pix_t ref_filter (
    input pix_t w [0:8], input logic [1:0] cfg
  );
    pix_t sorted [0:8];
    pix_t tmp;
    int   gxp, gxn, gyp, gyn, mag;

    case (cfg)
      F_MIN, F_MAX, F_MED: begin
        for (int i = 0; i < 9; i++) sorted[i] = w[i];
        for (int i = 0; i < 8; i++)
          for (int j = 0; j < 8-i; j++)
            if (sorted[j] > sorted[j+1]) begin
              tmp = sorted[j]; sorted[j] = sorted[j+1]; sorted[j+1] = tmp;
            end
        if      (cfg == F_MIN) ref_filter = sorted[0];
        else if (cfg == F_MAX) ref_filter = sorted[8];
        else                   ref_filter = sorted[4];
      end
      default: begin   // SOBEL
        gxp = w[2] + 2*w[5] + w[8];
        gxn = w[0] + 2*w[3] + w[6];
        gyp = w[6] + 2*w[7] + w[8];
        gyn = w[0] + 2*w[1] + w[2];
        mag = ((gxp > gxn) ? gxp-gxn : gxn-gxp)
            + ((gyp > gyn) ? gyp-gyn : gyn-gyp);
        ref_filter = (mag > 2**PIX_BW - 1) ? pix_t'('1) : pix_t'(mag);
      end
    endcase
  endfunction

  function automatic string cfg_name (input logic [1:0] c);
    case (c)
      F_MIN:   cfg_name = "MIN";
      F_MAX:   cfg_name = "MAX";
      F_MED:   cfg_name = "MEDIAN";
      default: cfg_name = "SOBEL";
    endcase
  endfunction

  //==========================================================================
  // Скоребоард
  //==========================================================================
  pix_t exp_q [$];
  string name_q [$];
  int   n_checks = 0;
  int   n_errors = 0;

  //==========================================================================
  // tb_mst -- пише вікно одним бурстом на 9 beat'ів
  //==========================================================================
  task automatic tb_write_window (
    input pix_t win_in [0:8],
    input int   aw_delay = 0,
    input int   w_gap    = 0
  );
    fork
      //-------------------------------------------------------------- AW
      begin
        repeat (aw_delay) @(posedge aclk);
        bus_in.awid    <= 4'h1;
        bus_in.awaddr  <= SRC;
        bus_in.awlen   <= 8'd8;          // 9 beat'ів
        bus_in.awsize  <= 3'd2;          // 4 байти
        bus_in.awburst <= 2'b01;         // INCR
        bus_in.awlock  <= 1'b0;
        bus_in.awcache <= 4'b0000;
        bus_in.awprot  <= 3'b000;
        bus_in.awqos   <= 4'b0000;
        bus_in.awvalid <= 1'b1;
        do @(posedge aclk); while (!bus_in.awready);
        bus_in.awvalid <= 1'b0;
        bus_in.awaddr  <= 'x;
      end

      //--------------------------------------------------------------- W
      begin
        for (int i = 0; i < 9; i++) begin
          if (w_gap > 0 && i > 0) begin
            bus_in.wvalid <= 1'b0;
            bus_in.wdata  <= 'x;
            repeat (w_gap) @(posedge aclk);
          end
          bus_in.wdata  <= DATA_BW'(win_in[i]);
          bus_in.wstrb  <= '1;
          bus_in.wlast  <= (i == 8);
          bus_in.wvalid <= 1'b1;
          do @(posedge aclk); while (!bus_in.wready);
        end
        bus_in.wvalid <= 1'b0;
        bus_in.wlast  <= 1'b0;
        bus_in.wdata  <= 'x;
        bus_in.wstrb  <= 'x;
      end

      //--------------------------------------------------------------- B
      begin
        bus_in.bready <= 1'b1;
        do @(posedge aclk); while (!bus_in.bvalid);
        if (bus_in.bresp !== 2'b00) begin
          $error("tb_mst: BRESP = %b", bus_in.bresp);
          n_errors++;
        end
        bus_in.bready <= 1'b0;
      end
    join
  endtask

  //==========================================================================
  // tb_slv -- приймає одиничний запис результату
  //==========================================================================
  logic tb_slv_bp = 1'b0;   // увімкнути backpressure

  logic               slv_aw_done;
  logic [ID_BW-1:0]   slv_id;
  logic [ADDR_BW-1:0] slv_addr;

  initial begin
    bus_out.awready <= 1'b0;
    bus_out.wready  <= 1'b0;
    bus_out.bvalid  <= 1'b0;
    bus_out.bresp   <= 2'b00;
    bus_out.bid     <= '0;
    slv_aw_done      = 1'b0;

    @(posedge arstn);

    forever begin
      pix_t got, exp;
      string nm;

      // AW
      bus_out.awready <= 1'b1;
      do @(posedge aclk); while (!bus_out.awvalid);
      slv_id   = bus_out.awid;
      slv_addr = bus_out.awaddr;
      bus_out.awready <= 1'b0;

      if (slv_addr !== DST) begin
        $error("tb_slv: адреса 0x%08h, очікувалась 0x%08h", slv_addr, DST);
        n_errors++;
      end

      // W -- з опційним backpressure
      if (tb_slv_bp) repeat ($urandom_range(1, 4)) @(posedge aclk);
      bus_out.wready <= 1'b1;
      do @(posedge aclk); while (!bus_out.wvalid);
      got = bus_out.wdata[PIX_BW-1:0];
      if (!bus_out.wlast) begin
        $error("tb_slv: WLAST не виставлений на одиничному записі");
        n_errors++;
      end
      bus_out.wready <= 1'b0;

      // звірка
      if (exp_q.size() == 0) begin
        $error("tb_slv: зайвий результат 0x%02h", got);
        n_errors++;
      end
      else begin
        exp = exp_q.pop_front();
        nm  = name_q.pop_front();
        n_checks++;
        if (got !== exp) begin
          $error("%s: очікувалось %0d (0x%02h), отримано %0d (0x%02h)",
                 nm, exp, exp, got, got);
          n_errors++;
        end
        else
          $display("%s: PASS -> %0d", nm, got);
      end

      // B
      if (tb_slv_bp) repeat ($urandom_range(0, 3)) @(posedge aclk);
      bus_out.bid    <= slv_id;
      bus_out.bresp  <= 2'b00;
      bus_out.bvalid <= 1'b1;
      do @(posedge aclk); while (!bus_out.bready);
      bus_out.bvalid <= 1'b0;
    end
  end

  // канал читання bus_out не використовується
  assign bus_out.arready = 1'b0;
  assign bus_out.rvalid  = 1'b0;
  assign bus_out.rdata   = '0;
  assign bus_out.rresp   = 2'b00;
  assign bus_out.rlast   = 1'b0;
  assign bus_out.rid     = '0;

  // канал читання bus_in з боку майстра не використовується
  assign bus_in.arvalid = 1'b0;
  assign bus_in.arid    = '0;
  assign bus_in.araddr  = '0;
  assign bus_in.arlen   = 8'd0;
  assign bus_in.arsize  = 3'd2;
  assign bus_in.arburst = 2'b01;
  assign bus_in.arlock  = 1'b0;
  assign bus_in.arcache = 4'b0000;
  assign bus_in.arprot  = 3'b000;
  assign bus_in.arqos   = 4'b0000;
  assign bus_in.rready  = 1'b0;

  //==========================================================================
  // Один прогін
  //==========================================================================
  task automatic run_one (
    input string      nm,
    input pix_t       w [0:8],
    input logic [1:0] cfg,
    input int         aw_delay = 0,
    input int         w_gap    = 0
  );
    cfg_select <= cfg;
    dst_addr   <= DST;
    @(posedge aclk);

    exp_q.push_back(ref_filter(w, cfg));
    name_q.push_back($sformatf("%s (%s)", nm, cfg_name(cfg)));

    tb_write_window(w, aw_delay, w_gap);
    repeat (4) @(posedge aclk);
  endtask

  //==========================================================================
  // Сценарій
  //==========================================================================
  pix_t win_a [0:8] = '{10, 20, 30, 40, 50, 60, 70, 80, 90};
  pix_t win_t [0:8];

  initial begin
    bus_in.awvalid <= 1'b0;
    bus_in.wvalid  <= 1'b0;
    bus_in.bready  <= 1'b0;
    bus_in.wlast   <= 1'b0;
    cfg_select     <= F_MIN;
    dst_addr       <= DST;

    arstn = 1'b0;
    repeat (5) @(posedge aclk);
    arstn = 1'b1;
    repeat (2) @(posedge aclk);

    //------------------------------------------------------------------------
    $display("\n=== Базове вікно {10,20,...,90} ===");
    // min=10, max=90, median=50
    // sobel: |Gx|=80, |Gy|=240 -> 320 -> насичення 255
    run_one("T1", win_a, F_MIN);
    run_one("T2", win_a, F_MAX);
    run_one("T3", win_a, F_MED);
    run_one("T4", win_a, F_SOBEL);

    //------------------------------------------------------------------------
    $display("\n=== Виродження: усі пікселі однакові ===");
    foreach (win_t[i]) win_t[i] = 8'd77;
    run_one("T5", win_t, F_MED);      // 77
    run_one("T6", win_t, F_SOBEL);    // 0

    //------------------------------------------------------------------------
    $display("\n=== Межі діапазону ===");
    win_t = '{0, 0, 0, 0, 255, 0, 0, 0, 0};
    run_one("T7", win_t, F_MED);      // 0 -- один викид не зміщує медіану
    run_one("T8", win_t, F_MAX);      // 255

    //------------------------------------------------------------------------
    $display("\n=== Собель: чисті краї ===");
    win_t = '{0, 0, 255, 0, 0, 255, 0, 0, 255};
    run_one("T9",  win_t, F_SOBEL);   // вертикальний -> 255
    win_t = '{0, 0, 0, 0, 0, 0, 255, 255, 255};
    run_one("T10", win_t, F_SOBEL);   // горизонтальний -> 255

    //------------------------------------------------------------------------
    $display("\n=== Паузи на вхідній шині ===");
    foreach (win_t[i]) win_t[i] = pix_t'($urandom_range(0, 255));
    run_one("T11", win_t, F_MED, /*aw_delay*/ 3, /*w_gap*/ 2);

    //------------------------------------------------------------------------
    $display("\n=== Backpressure на вихідній шині ===");
    tb_slv_bp = 1'b1;
    for (int t = 0; t < 5; t++) begin
      foreach (win_t[i]) win_t[i] = pix_t'($urandom_range(0, 255));
      run_one($sformatf("T12.%0d", t), win_t, 2'($urandom_range(0, 3)));
    end
    tb_slv_bp = 1'b0;

    //------------------------------------------------------------------------
    $display("\n=== Випадкові вікна, усі режими ===");
    for (int t = 0; t < 20; t++) begin
      foreach (win_t[i]) win_t[i] = pix_t'($urandom_range(0, 255));
      run_one($sformatf("R%0d", t), win_t, 2'($urandom_range(0, 3)));
    end

    //------------------------------------------------------------------------
    wait (exp_q.size() == 0);
    repeat (10) @(posedge aclk);

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "РЕЗУЛЬТАТ: PASS" : "РЕЗУЛЬТАТ: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  //==========================================================================
  initial begin
    #(CLK_P * 30000);
    $error("Watchdog: тест завис (перевірено %0d)", n_checks);
    $finish;
  end

  initial begin
    $dumpfile("tb_axi_filter.vcd");
    $dumpvars(0, tb_axi_filter);
  end

endmodule