//==============================================================================
// sd_card_model -- поведінкова модель microSD (SDHC) у нативному режимі для
// тестбенчів. Не синтезується.
//
//   CMD: читає команду по фронту CLK, перевіряє CRC7, відповідає по спадах
//        через Ncr = 2 такти. Команди: 0, 2, 3, 7 (R1b), 8, 9, 12 (R1b), 13, 16,
//        17, 18, 24, 55, ACMD6 (ширина шини), ACMD41 (готова з 3-ї спроби).
//   DAT: блоки 512 байт у 4-бітному режимі з CRC16 кожної лінії; CMD18 шле
//        блоки підряд (Nac = NAC тактів між ними), поки не прийде CMD12; CMD24
//        приймає блок, відповідає CRC status (010 / 101) і тримає busy.
//   Пам'ять -- mem[], номер блоку = аргумент команди (адресація SDHC).
//
//   err_cmd_crc / err_dat_crc -- лічильники помилок, побачених карткою.
//==============================================================================
`timescale 1ns/1ps

module sd_card_model #(
  parameter int BLOCKS = 64,
  parameter int NAC    = 6,            // тактів від відповіді / між блоками
  parameter int BUSY   = 40            // тактів busy після запису / R1b
)(
  input  wire       sd_clk,
  inout  wire       cmd,
  inout  wire [3:0] dat
);

  logic       cmd_oe = 1'b0, cmd_o = 1'b1;
  logic       dat_oe = 1'b0;
  logic [3:0] dat_o = 4'hF;
  assign #2 cmd = cmd_oe ? cmd_o : 1'bz;
  assign #2 dat = dat_oe ? dat_o : 4'bzzzz;

  logic [7:0] mem [0:BLOCKS*512-1];

  int   err_cmd_crc = 0, err_dat_crc = 0;
  int   n_cmds = 0;
  logic bus4 = 1'b0, app = 1'b0;
  int   acmd41_n = 0;
  logic [15:0] rca = 16'h1234;

  // задачі для автомата DAT
  typedef enum {J_NONE, J_READ1, J_READN, J_WRITE, J_BUSY} job_t;
  typedef struct { job_t j; int blk; } job_s;
  job_s  jobs[$];                       // черга: команда може прийти, поки DAT зайнятий
  logic  stop = 1'b0;

  function automatic logic [6:0] crc7(input logic [39:0] v);
    logic [6:0] c = '0;
    for (int i = 39; i >= 0; i--) begin
      logic fb = c[6] ^ v[i];
      c = {c[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
    end
    return c;
  endfunction

  function automatic logic [15:0] crc16_step(input logic [15:0] c, input logic b);
    logic fb = c[15] ^ b;
    return {c[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
  endfunction

  //------------------------------------------------------------- CMD --------
  task automatic send_bits(input logic [135:0] v, input int n);
    repeat (2) @(posedge sd_clk);                       // Ncr
    for (int i = n - 1; i >= 0; i--) begin
      @(negedge sd_clk);
      #3 cmd_oe = 1'b1; cmd_o = v[i];
    end
    @(negedge sd_clk);
    #3 cmd_oe = 1'b0; cmd_o = 1'b1;
  endtask

  task automatic r1(input logic [5:0] idx, input logic [31:0] st);
    logic [39:0] h = {2'b00, idx, st};
    send_bits({88'd0, h, crc7(h), 1'b1}, 48);
  endtask

  task automatic r2(input logic [127:0] reg_v);
    send_bits({2'b00, 6'h3F, reg_v[127:1], 1'b1}, 136);
  endtask

  initial begin : cmd_loop
    logic [47:0] f;
    forever begin
      @(posedge sd_clk);
      if (cmd === 1'b0 && !cmd_oe) begin
        f = '0;
        for (int i = 46; i >= 0; i--) begin
          @(posedge sd_clk);
          f[i] = cmd;
        end
        n_cmds++;
        if (crc7(f[47:8]) != f[7:1]) begin
          err_cmd_crc++;
          $display("[card] CRC7 команди %0d не збігся", f[45:40]);
        end
        else handle(f[45:40], f[39:8]);
      end
    end
  end

  task automatic handle(input logic [5:0] idx, input logic [31:0] arg);
    logic was_app = app;
    app = 1'b0;
    if (was_app) begin
      case (idx)
        6'd6:  begin bus4 = (arg[1:0] == 2'b10); r1(idx, 32'h0000_0920); end
        6'd41: begin
          acmd41_n++;
          // R3: OCR, біт 31 -- готова, біт 30 -- SDHC; CRC = 1111111
          send_bits({88'd0, 2'b00, 6'h3F, (acmd41_n >= 3) ? 32'hC0FF_8000 : 32'h40FF_8000, 7'h7F, 1'b1}, 48);
        end
        default: r1(idx, 32'h0000_0920);
      endcase
      return;
    end
    case (idx)
      6'd0:  ;                                               // без відповіді
      6'd2:  r2(128'h0353_4453_4436_3447_8012_3456_7801_7F01);
      6'd3:  r1(idx, {rca, 16'h0520});                       // R6
      6'd7:  begin r1(idx, 32'h0000_0700); jobs.push_back('{J_BUSY, 0}); end
      6'd8:  r1(idx, arg);                                   // R7: луна
      6'd9:  r2(128'h400E_0032_5B59_0000_3B37_7F80_0A40_0001);  // CSD v2, C_SIZE 0x3B37
      6'd12: begin stop = 1'b1; r1(idx, 32'h0000_0B00); jobs.push_back('{J_BUSY, 0}); end
      6'd13: r1(idx, 32'h0000_0900);
      6'd16: r1(idx, 32'h0000_0900);
      6'd17: begin stop = 1'b0; jobs.push_back('{J_READ1, int'(arg)}); r1(idx, 32'h0000_0900); end
      6'd18: begin stop = 1'b0; jobs.push_back('{J_READN, int'(arg)}); r1(idx, 32'h0000_0900); end
      6'd24: begin r1(idx, 32'h0000_0900); jobs.push_back('{J_WRITE, int'(arg)}); end
      6'd55: begin app = 1'b1; r1(idx, 32'h0000_0120); end
      default: r1(idx, 32'h0040_0900);                       // illegal command
    endcase
  endtask

  //------------------------------------------------------------- DAT --------
  task automatic send_block(input int blk);
    logic [15:0] c [4];
    logic [3:0]  nib;
    for (int l = 0; l < 4; l++) c[l] = '0;
    @(negedge sd_clk); #3 dat_oe = 1'b1; dat_o = 4'h0;          // старт
    for (int n = 0; n < 1024 && !stop; n++) begin
      logic [7:0] b = mem[(blk % BLOCKS) * 512 + n / 2];
      nib = (n % 2 == 0) ? b[7:4] : b[3:0];
      @(negedge sd_clk); #3 dat_o = nib;
      for (int l = 0; l < 4; l++) c[l] = crc16_step(c[l], nib[l]);
    end
    for (int k = 15; k >= 0 && !stop; k--) begin
      @(negedge sd_clk); #3 for (int l = 0; l < 4; l++) dat_o[l] = c[l][k];
    end
    @(negedge sd_clk); #3 dat_o = 4'hF;                           // стоп
    @(negedge sd_clk); #3 dat_oe = 1'b0;
  endtask

  task automatic recv_block(input int blk);
    logic [15:0] c [4], rc [4];
    logic [3:0]  nib, hi;
    logic        bad;
    for (int l = 0; l < 4; l++) c[l] = '0;
    do @(posedge sd_clk); while (dat[0] !== 1'b0);                // старт
    for (int n = 0; n < 1024; n++) begin
      @(posedge sd_clk);
      nib = dat;
      for (int l = 0; l < 4; l++) c[l] = crc16_step(c[l], nib[l]);
      if (n % 2 == 0) hi = nib;
      else mem[(blk % BLOCKS) * 512 + n / 2] = {hi, nib};
    end
    for (int k = 15; k >= 0; k--) begin
      @(posedge sd_clk);
      for (int l = 0; l < 4; l++) rc[l][k] = dat[l];
    end
    @(posedge sd_clk);                                            // стоп
    bad = 1'b0;
    for (int l = 0; l < 4; l++) if (rc[l] != c[l]) bad = 1'b1;
    if (bad) err_dat_crc++;
    // CRC status на DAT0 через 2 такти: 0, 010 (101 = помилка), 1; далі busy
    repeat (2) @(negedge sd_clk);
    begin
      logic [4:0] st = bad ? 5'b01011 : 5'b00101;
      for (int i = 4; i >= 0; i--) begin
        @(negedge sd_clk); #3 dat_oe = 1'b1; dat_o = {3'b111, st[i]};
      end
    end
    repeat (BUSY) begin @(negedge sd_clk); #3 dat_o = 4'b1110; end
    @(negedge sd_clk); #3 dat_o = 4'hF;
    @(negedge sd_clk); #3 dat_oe = 1'b0;
  endtask

  initial begin : dat_loop
    job_s js;
    forever begin
      wait (jobs.size() > 0);
      js = jobs.pop_front();
      case (js.j)
        J_READ1: begin
          repeat (NAC + 48) @(posedge sd_clk);       // після відповіді
          send_block(js.blk);
        end
        J_READN: begin
          int b = js.blk;
          repeat (NAC + 48) @(posedge sd_clk);
          while (!stop) begin
            send_block(b);
            b++;
            repeat (NAC) @(posedge sd_clk);
          end
          dat_oe = 1'b0;
        end
        J_WRITE: recv_block(js.blk);
        J_BUSY: begin                                // R1b: busy одразу після відповіді
          repeat (2) @(negedge sd_clk);
          repeat (BUSY) begin @(negedge sd_clk); #3 dat_oe = 1'b1; dat_o = 4'b1110; end
          @(negedge sd_clk); #3 dat_oe = 1'b0; dat_o = 4'hF;
        end
        default: ;
      endcase
    end
  end

endmodule
