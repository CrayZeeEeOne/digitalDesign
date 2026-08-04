//==============================================================================
// tb_axi_slv -- тестбенч AXI4-слейва.
//
// Містить майстер-BFM (задачі axi_write / axi_read), референсну модель
// пам'яті та скоребоард. Перевіряє INCR, FIXED, WRAP, WSTRB, SLVERR
// і поведінку під backpressure.
//==============================================================================
`timescale 1ns/1ps

module tb_axi_slv;

  localparam int  ADDR_BW   = 32;
  localparam int  DATA_BW   = 32;
  localparam int  ID_BW     = 4;
  localparam int  STRB_BW   = DATA_BW/8;
  localparam int  MEM_DEPTH = 2048;
  localparam int  ADDR_LSB  = $clog2(STRB_BW);
  localparam time CLK_P     = 10ns;

  localparam logic [1:0] BURST_FIXED = 2'b00;
  localparam logic [1:0] BURST_INCR  = 2'b01;
  localparam logic [1:0] BURST_WRAP  = 2'b10;

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  typedef logic [DATA_BW-1:0] data_t;
  typedef logic [ADDR_BW-1:0] addr_t;

  //--------------------------------------------------------------------------
  logic aclk = 1'b0;
  logic arstn;
  always #(CLK_P/2) aclk = ~aclk;

  axi_if #(.ADDR_BW(ADDR_BW), .DATA_BW(DATA_BW), .ID_BW(ID_BW))
    bus (.aclk(aclk), .arstn(arstn));

  axi_slv #(.MEM_DEPTH(MEM_DEPTH)) dut (
    .aclk   (aclk),
    .arstn  (arstn),
    .sr_bus (bus.read_slv),
    .sw_bus (bus.write_slv)
  );

  //--------------------------------------------------------------------------
  // Референсна модель + статистика
  //--------------------------------------------------------------------------
  data_t ref_mem [0:MEM_DEPTH-1];
  int    n_checks = 0;
  int    n_errors = 0;

  task automatic check (input string name, input data_t got, exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      $error("%s: очікувалось 0x%08h, отримано 0x%08h", name, exp, got);
    end
  endtask

  task automatic check_resp (input string name, input logic [1:0] got, exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      $error("%s: RESP очікувався %b, отримано %b", name, exp, got);
    end
  endtask

  //--------------------------------------------------------------------------
  // Генератор адрес для референсної моделі
  //--------------------------------------------------------------------------
  function automatic addr_t ref_next_addr (
    input addr_t      curr, start,
    input logic [2:0] size,
    input logic [7:0] len,
    input logic [1:0] burst
  );
    addr_t step, total, aligned, wrap_lo;
    step    = addr_t'(1) << size;
    total   = (addr_t'(len) + 1) << size;
    aligned = (curr >> size) << size;
    case (burst)
      BURST_FIXED: ref_next_addr = curr;
      BURST_WRAP:  begin
        wrap_lo       = start & ~(total - 1);
        ref_next_addr = aligned + step;
        if (ref_next_addr == wrap_lo + total) ref_next_addr = wrap_lo;
      end
      default:     ref_next_addr = aligned + step;
    endcase
  endfunction

  //==========================================================================
  // Майстер-BFM: запис
  //==========================================================================
  task automatic axi_write (
    input  addr_t              addr,
    input  logic [7:0]         len,
    input  logic [2:0]         size,
    input  logic [1:0]         burst,
    input  logic [ID_BW-1:0]   id,
    input  data_t              data [],
    input  logic [STRB_BW-1:0] strb [],
    output logic [1:0]         resp,
    input  int                 aw_delay = 0,
    input  int                 w_gap    = 0
  );
    fork
      //---------------------------------------------------------------- AW
      begin
        repeat (aw_delay) @(posedge aclk);
        bus.awid    <= id;
        bus.awaddr  <= addr;
        bus.awlen   <= len;
        bus.awsize  <= size;
        bus.awburst <= burst;
        bus.awlock  <= 1'b0;
        bus.awcache <= 4'b0000;
        bus.awprot  <= 3'b000;
        bus.awqos   <= 4'b0000;
        bus.awvalid <= 1'b1;
        do @(posedge aclk); while (!bus.awready);
        bus.awvalid <= 1'b0;
        bus.awaddr  <= 'x;
      end

      //---------------------------------------------------------------- W
      begin
        for (int i = 0; i <= int'(len); i++) begin
          if (w_gap > 0 && i > 0) begin
            bus.wvalid <= 1'b0;
            bus.wdata  <= 'x;
            repeat (w_gap) @(posedge aclk);
          end
          bus.wdata  <= data[i];
          bus.wstrb  <= strb[i];
          bus.wlast  <= (i == int'(len));
          bus.wvalid <= 1'b1;
          do @(posedge aclk); while (!bus.wready);
        end
        bus.wvalid <= 1'b0;
        bus.wlast  <= 1'b0;
        bus.wdata  <= 'x;
        bus.wstrb  <= 'x;
      end

      //---------------------------------------------------------------- B
      begin
        bus.bready <= 1'b1;
        do @(posedge aclk); while (!bus.bvalid);
        resp = bus.bresp;
        if (bus.bid !== id)
          $error("BID: очікувався %0d, отримано %0d", id, bus.bid);
        bus.bready <= 1'b0;
      end
    join
  endtask

  //==========================================================================
  // Майстер-BFM: читання
  //==========================================================================
  task automatic axi_read (
    input  addr_t            addr,
    input  logic [7:0]       len,
    input  logic [2:0]       size,
    input  logic [1:0]       burst,
    input  logic [ID_BW-1:0] id,
    output data_t            data [],
    output logic [1:0]       resp,
    input  bit               backpressure = 1'b0
  );
    int i;
    data = new [int'(len) + 1];

    fork
      //---------------------------------------------------------------- AR
      begin
        bus.arid    <= id;
        bus.araddr  <= addr;
        bus.arlen   <= len;
        bus.arsize  <= size;
        bus.arburst <= burst;
        bus.arlock  <= 1'b0;
        bus.arcache <= 4'b0000;
        bus.arprot  <= 3'b000;
        bus.arqos   <= 4'b0000;
        bus.arvalid <= 1'b1;
        do @(posedge aclk); while (!bus.arready);
        bus.arvalid <= 1'b0;
        bus.araddr  <= 'x;
      end

      //---------------------------------------------------------------- R
      begin
        i = 0;
        forever begin
          if (backpressure) begin
            bus.rready <= 1'b0;
            repeat ($urandom_range(1, 3)) @(posedge aclk);
          end
          bus.rready <= 1'b1;
          @(posedge aclk);
          if (bus.rvalid) begin
            data[i] = bus.rdata;
            resp    = bus.rresp;
            if (bus.rid !== id)
              $error("RID: очікувався %0d, отримано %0d", id, bus.rid);
            if (bus.rlast) begin
              if (i != int'(len))
                $error("RLAST на beat'і %0d, очікувався %0d", i, len);
              break;
            end
            i++;
          end
        end
        bus.rready <= 1'b0;
      end
    join
  endtask

  //--------------------------------------------------------------------------
  // Допоміжні
  //--------------------------------------------------------------------------
  function automatic void mk_data (ref data_t d [], input int n, input int seed);
    d = new [n];
    foreach (d[i]) d[i] = data_t'(seed + i * 32'h0101_0101);
  endfunction

  function automatic void mk_strb (ref logic [STRB_BW-1:0] s [], input int n);
    s = new [n];
    foreach (s[i]) s[i] = '1;
  endfunction

  // застосувати запис до референсної моделі
  function automatic void ref_write (
    input addr_t              addr,
    input logic [7:0]         len,
    input logic [2:0]         size,
    input logic [1:0]         burst,
    input data_t              data [],
    input logic [STRB_BW-1:0] strb []
  );
    addr_t a = addr;
    for (int b = 0; b <= int'(len); b++) begin
      automatic int idx = a[ADDR_LSB +: $clog2(MEM_DEPTH)];
      for (int i = 0; i < STRB_BW; i++)
        if (strb[b][i]) ref_mem[idx][i*8 +: 8] = data[b][i*8 +: 8];
      a = ref_next_addr(a, addr, size, len, burst);
    end
  endfunction

  //==========================================================================
  // Сценарій
  //==========================================================================
  data_t              wd [];
  data_t              rd [];
  logic [STRB_BW-1:0] ws [];
  logic [1:0]         resp;
  addr_t              a;

  initial begin
    // ініціалізація сигналів майстра
    bus.awvalid <= 1'b0;  bus.wvalid <= 1'b0;  bus.bready <= 1'b0;
    bus.arvalid <= 1'b0;  bus.rready <= 1'b0;  bus.wlast  <= 1'b0;

    // backdoor-ініціалізація: DUT і референс однакові
    for (int i = 0; i < MEM_DEPTH; i++) begin
      automatic data_t v = data_t'(32'hA000_0000 + i);
      dut.mem[i] = v;
      ref_mem[i] = v;
    end

    arstn = 1'b0;
    repeat (5) @(posedge aclk);
    arstn = 1'b1;
    repeat (2) @(posedge aclk);

    //------------------------------------------------------------------------
    $display("\n=== T1: одиничний запис + читання (len=0, INCR) ===");
    mk_data(wd, 1, 32'hDEAD_0000);
    mk_strb(ws, 1);
    axi_write(32'h0000_0040, 8'd0, 3'd2, BURST_INCR, 4'h1, wd, ws, resp);
    check_resp("T1 write", resp, RESP_OKAY);
    ref_write(32'h0000_0040, 8'd0, 3'd2, BURST_INCR, wd, ws);

    axi_read(32'h0000_0040, 8'd0, 3'd2, BURST_INCR, 4'h1, rd, resp);
    check_resp("T1 read", resp, RESP_OKAY);
    check("T1 data", rd[0], wd[0]);

    //------------------------------------------------------------------------
    $display("\n=== T2: INCR-бурст 4 beat'и ===");
    mk_data(wd, 4, 32'h1111_0000);
    mk_strb(ws, 4);
    axi_write(32'h0000_0080, 8'd3, 3'd2, BURST_INCR, 4'h2, wd, ws, resp);
    check_resp("T2 write", resp, RESP_OKAY);
    ref_write(32'h0000_0080, 8'd3, 3'd2, BURST_INCR, wd, ws);

    axi_read(32'h0000_0080, 8'd3, 3'd2, BURST_INCR, 4'h2, rd, resp);
    foreach (rd[i]) check($sformatf("T2 beat %0d", i), rd[i], wd[i]);

    //------------------------------------------------------------------------
    $display("\n=== T3: WSTRB -- часткові байтові записи ===");
    // база: пишемо повне слово, потім затираємо окремі байти
    mk_data(wd, 1, 32'h0000_0000);
    mk_strb(ws, 1);
    axi_write(32'h0000_0100, 8'd0, 3'd2, BURST_INCR, 4'h3, wd, ws, resp);
    ref_write(32'h0000_0100, 8'd0, 3'd2, BURST_INCR, wd, ws);

    wd = new [1]; wd[0] = 32'hAABB_CCDD;
    ws = new [1]; ws[0] = 4'b0110;          // тільки байти 1 і 2
    axi_write(32'h0000_0100, 8'd0, 3'd2, BURST_INCR, 4'h3, wd, ws, resp);
    ref_write(32'h0000_0100, 8'd0, 3'd2, BURST_INCR, wd, ws);

    axi_read(32'h0000_0100, 8'd0, 3'd2, BURST_INCR, 4'h3, rd, resp);
    check("T3 wstrb", rd[0], 32'h00BB_CC00);

    //------------------------------------------------------------------------
    $display("\n=== T4: FIXED-бурст -- усі beat'и в одну адресу ===");
    mk_data(wd, 4, 32'h2222_0000);
    mk_strb(ws, 4);
    axi_write(32'h0000_0140, 8'd3, 3'd2, BURST_FIXED, 4'h4, wd, ws, resp);
    check_resp("T4 write", resp, RESP_OKAY);

    // виграє останній beat
    check("T4 fixed", dut.mem[32'h140 >> ADDR_LSB], wd[3]);
    // сусідня комірка не зачеплена
    check("T4 сусід", dut.mem[(32'h140 >> ADDR_LSB) + 1],
                      ref_mem[(32'h140 >> ADDR_LSB) + 1]);

    //------------------------------------------------------------------------
    $display("\n=== T5: WRAP -- 0x1004, size=4B, 4 beat'и ===");
    // очікуваний порядок адрес за специфікацією:
    //   0x1004 -> 0x1008 -> 0x100C -> 0x1000
    mk_data(wd, 4, 32'h3333_0000);
    mk_strb(ws, 4);
    axi_write(32'h0000_1004, 8'd3, 3'd2, BURST_WRAP, 4'h5, wd, ws, resp);
    check_resp("T5 write", resp, RESP_OKAY);

    check("T5 addr 0x1004", dut.mem[32'h1004 >> ADDR_LSB], wd[0]);
    check("T5 addr 0x1008", dut.mem[32'h1008 >> ADDR_LSB], wd[1]);
    check("T5 addr 0x100C", dut.mem[32'h100C >> ADDR_LSB], wd[2]);
    check("T5 addr 0x1000", dut.mem[32'h1000 >> ADDR_LSB], wd[3]);  // заворот

    // читання тим самим WRAP-бурстом має повернути ті самі дані
    axi_read(32'h0000_1004, 8'd3, 3'd2, BURST_WRAP, 4'h5, rd, resp);
    foreach (rd[i]) check($sformatf("T5 read beat %0d", i), rd[i], wd[i]);

    //------------------------------------------------------------------------
    $display("\n=== T6: SLVERR -- адреса поза пам'яттю ===");
    a = addr_t'(MEM_DEPTH << ADDR_LSB) + 32'h100;
    mk_data(wd, 1, 32'h4444_0000);
    mk_strb(ws, 1);
    axi_write(a, 8'd0, 3'd2, BURST_INCR, 4'h6, wd, ws, resp);
    check_resp("T6 write", resp, RESP_SLVERR);

    axi_read(a, 8'd0, 3'd2, BURST_INCR, 4'h6, rd, resp);
    check_resp("T6 read", resp, RESP_SLVERR);

    //------------------------------------------------------------------------
    $display("\n=== T7: backpressure на R-каналі ===");
    mk_data(wd, 8, 32'h5555_0000);
    mk_strb(ws, 8);
    axi_write(32'h0000_0200, 8'd7, 3'd2, BURST_INCR, 4'h7, wd, ws, resp);
    ref_write(32'h0000_0200, 8'd7, 3'd2, BURST_INCR, wd, ws);

    axi_read(32'h0000_0200, 8'd7, 3'd2, BURST_INCR, 4'h7, rd, resp, 1'b1);
    foreach (rd[i]) check($sformatf("T7 beat %0d", i), rd[i], wd[i]);

    //------------------------------------------------------------------------
    $display("\n=== T8: паузи на W-каналі ===");
    mk_data(wd, 4, 32'h6666_0000);
    mk_strb(ws, 4);
    axi_write(32'h0000_0280, 8'd3, 3'd2, BURST_INCR, 4'h8, wd, ws, resp,
              /*aw_delay*/ 3, /*w_gap*/ 2);
    check_resp("T8 write", resp, RESP_OKAY);
    ref_write(32'h0000_0280, 8'd3, 3'd2, BURST_INCR, wd, ws);

    axi_read(32'h0000_0280, 8'd3, 3'd2, BURST_INCR, 4'h8, rd, resp);
    foreach (rd[i]) check($sformatf("T8 beat %0d", i), rd[i], wd[i]);

    //------------------------------------------------------------------------
    $display("\n=== T9: byte-size бурст (size=0) ===");
    mk_data(wd, 4, 32'h7777_0000);
    ws = new [4];
    foreach (ws[i]) ws[i] = 4'b0001 << i;    // по одному байту в свій лейн
    axi_write(32'h0000_0300, 8'd3, 3'd0, BURST_INCR, 4'h9, wd, ws, resp);
    check_resp("T9 write", resp, RESP_OKAY);

    //------------------------------------------------------------------------
    repeat (10) @(posedge aclk);

    $display("\n----------------------------------------");
    $display("Перевірок: %0d, помилок: %0d", n_checks, n_errors);
    $display(n_errors == 0 ? "РЕЗУЛЬТАТ: PASS" : "РЕЗУЛЬТАТ: FAIL");
    $display("----------------------------------------\n");
    $finish;
  end

  //--------------------------------------------------------------------------
  initial begin
    #(CLK_P * 5000);
    $error("Watchdog: тест завис");
    $finish;
  end

  initial begin
    $dumpfile("tb_axi_slv.vcd");
    $dumpvars(0, tb_axi_slv);
  end

endmodule