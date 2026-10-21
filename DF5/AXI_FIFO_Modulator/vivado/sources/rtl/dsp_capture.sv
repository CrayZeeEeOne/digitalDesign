//==============================================================================
// dsp_capture -- одне захоплення для статичних екранів, у залізі замість
// vitis/src/app/capture.c (без спектра -- його рахує dsp_spectrum).
//
//   arm -> WARMUP (cfg_warmup відліків, оцінювачі встигають усталитися)
//       -> WAIT (до кінця пакета, щоб почати в паузі; не довше cfg_len)
//       -> RECORD (cfg_len відліків) -> DONE
//
// Під час запису:
//   raw   384 колонки: min/max вхідних I та Q (int8, крок 64 LSB, насичення
//         +-127), колонка c охоплює відліки [c*len/384, (c+1)*len/384)
//         (межі рахуються інкрементно з cfg_col_q = len/384, cfg_col_r = len%384)
//   pkt   до 2 пакетів: позиції початку/кінця burst і першого біта (у вхідних
//         відліках від початку запису), до 512 рішень слайсера, MSB першим
//
// Події демодулятора (tap_*) приходять із затримкою конвеєра, тож позиції
// пакетів пізніші за вхідні відліки на ~кілька децимованих відліків.
//==============================================================================
module dsp_capture (
  input  logic               clk,
  input  logic               rst,

  input  logic               arm,
  input  logic               abort,
  input  logic [31:0]        cfg_warmup,
  input  logic [31:0]        cfg_len,
  input  logic [15:0]        cfg_col_q,
  input  logic [15:0]        cfg_col_r,
  input  logic               cfg_nowait,     // після WARMUP одразу запис

  // прийнятий відлік потоку
  input  logic               in_fire,
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,

  // відводи демодулятора
  input  logic               tap_v,
  input  logic               tap_start,
  input  logic               tap_end,
  input  logic               tap_bit_v,
  input  logic               tap_bit,

  output logic               rec,            // цей такт відлік записується
  output logic [2:0]         st_state,       // 0 idle, 1 warmup, 2 wait, 3 record, 4 done
  output logic [31:0]        st_pos,
  output logic [31:0]        st_t0,          // номер вхідного відліку на початку запису
  output logic [1:0]         st_npkt,
  output logic               st_in_pkt,
  output logic [31:0]        pkt_start [0:1],
  output logic [31:0]        pkt_end   [0:1],
  output logic [31:0]        pkt_first [0:1],
  output logic [9:0]         pkt_nbits [0:1],

  // читання з AXI (синхронне)
  input  logic               rd_en,
  input  logic [8:0]         rd_raw_addr,    // 0..383
  input  logic [4:0]         rd_bits_addr,   // слово: пакет*16 + байти 4w..4w+3
  output logic [31:0]        rd_raw_data,
  output logic [31:0]        rd_bits_data
);

  localparam int COLS = 384;
  localparam int PKT_BITS = 512;

  typedef enum logic [2:0] {C_IDLE = 3'd0, C_WARMUP = 3'd1, C_WAIT = 3'd2,
                            C_RECORD = 3'd3, C_DONE = 3'd4} cst_t;
  cst_t cs;

  logic [31:0] count;                          // відліки у WARMUP / WAIT
  logic [31:0] pos;
  logic [31:0] in_cnt;                         // усі прийняті відліки від скиду

  assign rec = in_fire && cs == C_RECORD;

  //--------------------------------------------------------- колонки raw --
  logic [31:0] raw_mem [0:COLS-1];
  logic [8:0]  col;
  logic [31:0] edge_pos;                       // перший відлік наступної колонки
  logic [15:0] edge_rem;
  logic signed [7:0] i_lo, i_hi, q_lo, q_hi;
  logic        col_we;
  logic [8:0]  col_waddr;
  logic [31:0] col_wdata;

  function automatic logic signed [7:0] raw_q(input logic signed [15:0] x);
    logic signed [15:0] v;
    v = x >>> 6;
    if (v > 127)       return 8'sd127;
    else if (v < -127) return -8'sd127;
    else               return 8'(v);
  endfunction

  wire signed [7:0] xi = raw_q(in_i);
  wire signed [7:0] xq = raw_q(in_q);

  always_ff @(posedge clk) begin
    if (col_we) raw_mem[col_waddr] <= col_wdata;
    if (rd_en)  rd_raw_data <= raw_mem[rd_raw_addr];
  end

  //------------------------------------------------------------ пакети ----
  logic [7:0]  bits_b0 [0:31];                 // 4 байтові лани, 2 пакети x 16 слів
  logic [7:0]  bits_b1 [0:31];
  logic [7:0]  bits_b2 [0:31];
  logic [7:0]  bits_b3 [0:31];
  logic        in_pkt;
  logic [1:0]  npkt;
  logic [7:0]  shreg;
  logic        byte_we;
  logic [6:0]  byte_addr;                      // пакет*64 + байт
  logic [7:0]  byte_data;

  wire        cur  = npkt[0];                  // пакет, що пишеться (0 або 1)
  wire [9:0]  nb   = pkt_nbits[cur];

  always_ff @(posedge clk) begin
    if (byte_we) begin
      case (byte_addr[1:0])
        2'd0: bits_b0[byte_addr[6:2]] <= byte_data;
        2'd1: bits_b1[byte_addr[6:2]] <= byte_data;
        2'd2: bits_b2[byte_addr[6:2]] <= byte_data;
        default: bits_b3[byte_addr[6:2]] <= byte_data;
      endcase
    end
    if (rd_en) rd_bits_data <= {bits_b3[rd_bits_addr], bits_b2[rd_bits_addr],
                                bits_b1[rd_bits_addr], bits_b0[rd_bits_addr]};
  end

  //------------------------------------------------------------- стан -----
  always_ff @(posedge clk) begin
    col_we  <= 1'b0;
    byte_we <= 1'b0;
    if (rst) begin
      cs     <= C_IDLE;
      count  <= '0;
      pos    <= '0;
      in_cnt <= '0;
      in_pkt <= 1'b0;
      npkt   <= '0;
      st_t0  <= '0;
    end
    else begin
      if (in_fire) in_cnt <= in_cnt + 1'b1;

      case (cs)
        C_WARMUP: if (in_fire) begin
          if (count + 1'b1 >= cfg_warmup) begin
            cs    <= cfg_nowait ? C_RECORD : C_WAIT;
            count <= '0;
            st_t0 <= in_cnt + 1'b1;
          end
          else count <= count + 1'b1;
        end
        C_WAIT: begin
          if (tap_v && tap_end) begin
            cs <= C_RECORD;
            st_t0 <= in_cnt + (in_fire ? 32'd1 : 32'd0);
          end
          else if (in_fire) begin
            if (count + 1'b1 >= cfg_len) begin
              cs <= C_RECORD;
              st_t0 <= in_cnt + 1'b1;
            end
            count <= count + 1'b1;
          end
        end
        C_RECORD: begin
          //---------------------------------------------- колонки raw
          if (in_fire) begin
            if (pos >= edge_pos) begin
              logic [16:0] r;
              col_we    <= 1'b1;
              col_waddr <= col;
              col_wdata <= {q_hi, q_lo, i_hi, i_lo};
              col  <= col + 1'b1;
              r    = 17'(edge_rem) + 17'(cfg_col_r);
              if (r >= 17'(COLS)) begin
                edge_rem <= 16'(r - 17'(COLS));
                edge_pos <= edge_pos + 32'(cfg_col_q) + 32'd1;
              end
              else begin
                edge_rem <= 16'(r);
                edge_pos <= edge_pos + 32'(cfg_col_q);
              end
              i_lo <= xi; i_hi <= xi; q_lo <= xq; q_hi <= xq;
            end
            else begin
              if (xi < i_lo) i_lo <= xi;
              if (xi > i_hi) i_hi <= xi;
              if (xq < q_lo) q_lo <= xq;
              if (xq > q_hi) q_hi <= xq;
            end
          end

          //----------------------------------------------- пакети
          if (tap_v && tap_start && npkt < 2'd2) begin
            in_pkt          <= 1'b1;
            pkt_start[cur]  <= pos;
            pkt_nbits[cur]  <= '0;
            shreg           <= '0;
          end
          else if (in_pkt && tap_bit_v && nb < 10'(PKT_BITS)) begin
            logic [7:0] sh;
            sh = {shreg[6:0], tap_bit};
            if (nb == 0) pkt_first[cur] <= pos;
            pkt_nbits[cur] <= nb + 1'b1;
            shreg <= sh;
            if (nb[2:0] == 3'd7) begin
              byte_we   <= 1'b1;
              byte_addr <= {cur, nb[8:3]};
              byte_data <= sh;
            end
          end
          if (tap_v && tap_end && in_pkt) begin
            pkt_end[cur] <= pos;
            in_pkt       <= 1'b0;
            npkt         <= npkt + 1'b1;
            if (nb[2:0] != 3'd0) begin                  // неповний байт, вирівняти вліво
              byte_we   <= 1'b1;
              byte_addr <= {cur, nb[8:3]};
              byte_data <= shreg << (4'd8 - 4'(nb[2:0]));
            end
          end

          //------------------------------------------------ кінець
          if (in_fire) begin
            pos <= pos + 1'b1;
            if (pos + 1'b1 >= cfg_len) begin
              cs        <= C_DONE;
              col_we    <= 1'b1;                        // остання колонка
              col_waddr <= col;
              col_wdata <= (pos >= edge_pos) ? {xq, xq, xi, xi}
                         : {(xq > q_hi ? xq : q_hi), (xq < q_lo ? xq : q_lo),
                            (xi > i_hi ? xi : i_hi), (xi < i_lo ? xi : i_lo)};
              if (in_pkt) begin
                pkt_end[cur] <= pos + 1'b1;
                in_pkt       <= 1'b0;
                npkt         <= npkt + 1'b1;
                if (nb[2:0] != 3'd0) begin
                  byte_we   <= 1'b1;
                  byte_addr <= {cur, nb[8:3]};
                  byte_data <= shreg << (4'd8 - 4'(nb[2:0]));
                end
              end
            end
          end
        end
        default: ;
      endcase

      if (arm) begin
        cs       <= C_WARMUP;
        count    <= '0;
        pos      <= '0;
        col      <= '0;
        edge_pos <= 32'(cfg_col_q);
        edge_rem <= cfg_col_r;
        i_lo <= 8'sd127; i_hi <= -8'sd127; q_lo <= 8'sd127; q_hi <= -8'sd127;
        in_pkt   <= 1'b0;
        npkt     <= '0;
        for (int k = 0; k < 2; k++) begin
          pkt_start[k] <= '0; pkt_end[k] <= '0; pkt_first[k] <= '0; pkt_nbits[k] <= '0;
        end
      end
      else if (abort) cs <= C_IDLE;
    end
  end

  assign st_state  = cs;
  assign st_pos    = pos;
  assign st_npkt   = npkt;
  assign st_in_pkt = in_pkt;

endmodule
