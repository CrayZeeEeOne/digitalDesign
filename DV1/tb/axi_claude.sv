//==============================================================================
// tb_img_filter -- самоперевірний тестбенч на 5 транзакцій.
//
// Перевіряє: чотири режими фільтра, насичення в режимі Собеля,
// коректність handshake під випадковим backpressure на вихідному каналі.
//==============================================================================
`timescale 1ns/1ps

module tb_img_filter;

  localparam int  DATA_BW     = 8;
  localparam int  WINDOW_SIZE = 9;
  localparam int  TDATA_BW    = WINDOW_SIZE * DATA_BW;
  localparam time CLK_P       = 10ns;
  localparam int  N_TRANS     = 5;

  typedef logic [DATA_BW-1:0] pix_t;

  localparam logic [1:0] F_MIN   = 2'b00;
  localparam logic [1:0] F_MAX   = 2'b01;
  localparam logic [1:0] F_MED   = 2'b10;
  localparam logic [1:0] F_SOBEL = 2'b11;

  //--------------------------------------------------------------------------
  // Такт і скид
  //--------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rstn;

  always #(CLK_P/2) clk = ~clk;

  //--------------------------------------------------------------------------
  // Сигнали DUT
  //--------------------------------------------------------------------------
  logic [1:0]          cfg_select;

  logic                in_tvalid;
  logic                in_tready;
  logic [TDATA_BW-1:0] in_tdata;

  logic                out_tvalid;
  logic                out_tready;
  logic [DATA_BW-1:0]  out_tdata;

  img_filter_top #(
    .DATA_BW     (DATA_BW),
    .WINDOW_SIZE (WINDOW_SIZE)
  ) dut (
    .i_clk             (clk),
    .i_rstn            (rstn),
    .i_config_select   (cfg_select),
    .i_axis_in_tvalid  (in_tvalid),
    .o_axis_in_tready  (in_tready),
    .i_axis_in_tdata   (in_tdata),
    .o_axis_out_tvalid (out_tvalid),
    .i_axis_out_tready (out_tready),
    .o_axis_out_tdata  (out_tdata)
  );

  // маркери трансферів -- зручно бачити межі транзакцій на хвилі,
  // навіть коли tdata не змінюється
  logic xfer_in, xfer_out;
  assign xfer_in  = in_tvalid  && in_tready;
  assign xfer_out = out_tvalid && out_tready;

  // прапорці покриття flow control
  logic saw_tvalid_low = 1'b0;   // tvalid просів між транзакціями
  logic saw_in_stall   = 1'b0;   // tready просів під backpressure

  always @(posedge clk) begin
    if (rstn) begin
      if (!in_tvalid)              saw_tvalid_low <= 1'b1;
      if (in_tvalid && !in_tready) saw_in_stall   <= 1'b1;
    end
  end

  //--------------------------------------------------------------------------
  // Референсна модель
  //--------------------------------------------------------------------------
  function automatic pix_t ref_filter (
    input pix_t       win [0:WINDOW_SIZE-1],
    input logic [1:0] cfg
  );
    pix_t sorted [0:WINDOW_SIZE-1];
    pix_t tmp;
    int   gx_pos, gx_neg, gy_pos, gy_neg, mag;

    case (cfg)
      F_MIN, F_MAX, F_MED: begin
        sorted = win;
        // бульбашкове сортування -- модель, не RTL
        for (int i = 0; i < WINDOW_SIZE-1; i++)
          for (int j = 0; j < WINDOW_SIZE-1-i; j++)
            if (sorted[j] > sorted[j+1]) begin
              tmp        = sorted[j];
              sorted[j]  = sorted[j+1];
              sorted[j+1]= tmp;
            end
        if      (cfg == F_MIN) ref_filter = sorted[0];
        else if (cfg == F_MAX) ref_filter = sorted[WINDOW_SIZE-1];
        else                   ref_filter = sorted[4];
      end

      default: begin  // F_SOBEL
        gx_pos = win[2] + 2*win[5] + win[8];
        gx_neg = win[0] + 2*win[3] + win[6];
        gy_pos = win[6] + 2*win[7] + win[8];
        gy_neg = win[0] + 2*win[1] + win[2];
        mag    = ((gx_pos > gx_neg) ? gx_pos-gx_neg : gx_neg-gx_pos)
               + ((gy_pos > gy_neg) ? gy_pos-gy_neg : gy_neg-gy_pos);
        ref_filter = (mag > (2**DATA_BW - 1)) ? pix_t'('1) : pix_t'(mag);
      end
    endcase
  endfunction

  function automatic logic [TDATA_BW-1:0] pack (input pix_t win [0:WINDOW_SIZE-1]);
    for (int i = 0; i < WINDOW_SIZE; i++) pack[i*DATA_BW +: DATA_BW] = win[i];
  endfunction

  //--------------------------------------------------------------------------
  // Скоребоард
  //--------------------------------------------------------------------------
  typedef struct {
    pix_t  expected;
    string name;
  } item_t;

  item_t exp_q [$];
  int    n_checked = 0;
  int    n_errors  = 0;

  //--------------------------------------------------------------------------
  // Драйвер вхідного каналу
  //--------------------------------------------------------------------------
  // gap = 0 -> наступний send() перезапише сигнали в тому ж NBA-регіоні,
  //            tvalid не просяде -> справжній back-to-back.
  // gap > 0 -> tvalid знімається на gap тактів (видно на хвилі).
  task automatic send (
    input pix_t       win [0:WINDOW_SIZE-1],
    input logic [1:0] cfg,
    input string      name,
    input int         gap = 1
  );
    item_t it;
    it.expected = ref_filter(win, cfg);
    it.name     = name;
    exp_q.push_back(it);

    in_tdata   <= pack(win);
    cfg_select <= cfg;
    in_tvalid  <= 1'b1;

    do @(posedge clk); while (!in_tready);   // трансфер відбувся на цьому фронті

    if (gap > 0) begin
      in_tvalid  <= 1'b0;
      in_tdata   <= 'x;                      // ловимо, якщо DUT читає поза handshake
      cfg_select <= 'x;
      repeat (gap) @(posedge clk);
    end
  endtask

  //--------------------------------------------------------------------------
  // Монітор вихідного каналу
  //--------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rstn && out_tvalid && out_tready) begin
      item_t it;
      if (exp_q.size() == 0) begin
        $error("[%0t] Зайва транзакція на виході: 0x%02h", $time, out_tdata);
        n_errors++;
      end
      else begin
        it = exp_q.pop_front();
        n_checked++;
        if (out_tdata !== it.expected) begin
          $error("[%0t] %s: очікувалось 0x%02h (%0d), отримано 0x%02h (%0d)",
                 $time, it.name, it.expected, it.expected, out_tdata, out_tdata);
          n_errors++;
        end
        else begin
          $display("[%0t] %s: PASS -> 0x%02h (%0d)",
                   $time, it.name, out_tdata, out_tdata);
        end
      end
    end
  end

  //--------------------------------------------------------------------------
  // Генератор backpressure на вихідному каналі
  //--------------------------------------------------------------------------
  initial begin
    out_tready <= 1'b0;
    @(posedge rstn);
    repeat (2) @(posedge clk);
    forever begin
      out_tready <= 1'b1;
      repeat ($urandom_range(2, 6)) @(posedge clk);
      out_tready <= 1'b0;
      repeat ($urandom_range(1, 4)) @(posedge clk);
    end
  end

  //--------------------------------------------------------------------------
  // Основний сценарій
  //--------------------------------------------------------------------------
  pix_t win_a [0:WINDOW_SIZE-1] = '{10, 20, 30, 40, 50, 60, 70, 80, 90};
  pix_t win_r [0:WINDOW_SIZE-1];

  initial begin
    in_tvalid  <= 1'b0;
    in_tdata   <= '0;
    cfg_select <= F_MIN;

    rstn = 1'b0;
    repeat (5) @(posedge clk);
    rstn = 1'b1;
    repeat (2) @(posedge clk);

    // 1..4 -- одне й те саме вікно, усі чотири режими.
    // Очікувано: min=10, max=90, median=50, sobel=|80|+|240|=320 -> насичення 255.
    //
    // Паузи підібрані так, щоб на хвилі були обидва патерни:
    //   T1->T2  впритул, tvalid не просідає
    //   T2->T3  пауза 2 такти, tvalid падає в 0
    //   T3->T4  впритул
    //   T4->T5  пауза 4 такти, конвеєр повністю спорожняється
    send(win_a, F_MIN,   "T1 min",              0);
    send(win_a, F_MAX,   "T2 max",              2);
    send(win_a, F_MED,   "T3 median",           0);
    send(win_a, F_SOBEL, "T4 sobel (насичення)", 4);

    // 5 -- випадкове вікно, медіана
    foreach (win_r[i]) win_r[i] = $urandom_range(0, 2**DATA_BW - 1);
    send(win_r, F_MED,   "T5 median (random)",  1);

    // чекаємо, доки конвеєр спорожніє
    wait (exp_q.size() == 0);
    repeat (5) @(posedge clk);

    $display("----------------------------------------");
    $display("Перевірено транзакцій: %0d / %0d", n_checked, N_TRANS);
    $display("tvalid просідав в 0  : %s", saw_tvalid_low ? "так" : "НІ");
    $display("tready просідав в 0  : %s", saw_in_stall   ? "так" : "НІ");
    if (n_errors == 0 && n_checked == N_TRANS && saw_tvalid_low && saw_in_stall)
      $display("РЕЗУЛЬТАТ: PASS");
    else
      $display("РЕЗУЛЬТАТ: FAIL (помилок: %0d)", n_errors);
    $display("----------------------------------------");
    $finish;
  end

  //--------------------------------------------------------------------------
  // Watchdog
  //--------------------------------------------------------------------------
  initial begin
    #(CLK_P * 2000);
    $error("Watchdog: тест завис (перевірено %0d з %0d)", n_checked, N_TRANS);
    $finish;
  end

  //--------------------------------------------------------------------------
  // Протокольні перевірки AXI-Stream
  //--------------------------------------------------------------------------
  // TVALID не знімається без handshake
  property p_valid_stable;
    @(posedge clk) disable iff (!rstn)
      (in_tvalid && !in_tready) |=> in_tvalid;
  endproperty
  assert property (p_valid_stable)
    else $error("[%0t] Вхідний TVALID знявся без handshake", $time);

  // TDATA стабільний, поки TVALID утримується без handshake
  property p_data_stable;
    @(posedge clk) disable iff (!rstn)
      (in_tvalid && !in_tready) |=> $stable(in_tdata);
  endproperty
  assert property (p_data_stable)
    else $error("[%0t] Вхідний TDATA змінився без handshake", $time);

  // те саме на виході -- це вже перевірка DUT
  property p_out_valid_stable;
    @(posedge clk) disable iff (!rstn)
      (out_tvalid && !out_tready) |=> out_tvalid && $stable(out_tdata);
  endproperty
  assert property (p_out_valid_stable)
    else $error("[%0t] Вихідний канал порушив стабільність під backpressure", $time);

  //--------------------------------------------------------------------------
  initial begin
    $dumpfile("tb_img_filter.vcd");
    $dumpvars(0, tb_img_filter);
  end

endmodule