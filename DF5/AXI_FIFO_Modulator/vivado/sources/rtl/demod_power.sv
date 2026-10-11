//==============================================================================
// demod_power -- потужність, рівень шуму, детектор пакета (burst).
//
//   p      = i^2 + q^2                      (32 біт)
//   pavg  += (p - pavg) >> 4               швидке середнє
//   noise += (pavg - noise) >> 8           лише поза пакетом (перші 1024
//                                          відліки після скиду -- >> 4,
//                                          щоб швидко "сісти" на рівень)
//   thr_on = BURST_THR, або 8*noise (мін. 64), якщо BURST_THR = 0
//   burst  вмикається при pavg > thr_on, вимикається при pavg < thr_on/2
//
// dphi і прапор burst виходять вирівняними з тим самим відліком.
// Латентність: 3 такти.
//==============================================================================
module demod_power (
  input  logic               clk,
  input  logic               rst,

  input  logic [31:0]        burst_thr,     // 0 = авто

  input  logic               in_valid,
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,
  input  logic signed [15:0] in_dphi,

  output logic               out_valid,
  output logic signed [15:0] out_dphi,
  output logic               burst,         // стан для цього відлiку
  output logic               burst_start,   // перший відлік пакета
  output logic               burst_end,     // перший відлік після пакета

  output logic [31:0]        pavg,
  output logic [31:0]        noise,
  output logic [31:0]        thr_on,
  output logic               warmup_done,
  output logic [31:0]        burst_len,     // децимованих відліків у пакеті
  output logic [31:0]        burst_peak,    // максимум pavg у пакеті
  output logic [31:0]        burst_pwr      // повільне середнє pavg у пакеті
);

  //---------------------------------------------------- стадія 1: квадрати
  logic               v1;
  logic signed [31:0] sq_i, sq_q;
  logic signed [15:0] dphi1;

  always_ff @(posedge clk) begin
    v1    <= in_valid && !rst;
    sq_i  <= in_i * in_i;
    sq_q  <= in_q * in_q;
    dphi1 <= in_dphi;
  end

  //---------------------------------------------------- стадія 2: сума ----
  logic               v2;
  logic [31:0]        p2;
  logic signed [15:0] dphi2;

  always_ff @(posedge clk) begin
    v2    <= v1 && !rst;
    p2    <= 32'(sq_i) + 32'(sq_q);
    dphi2 <= dphi1;
  end

  //------------------------------------- стадія 3: IIR і детектор ---------
  logic [10:0] warm_cnt;
  logic        burst_q;

  wire signed [32:0] d_pavg  = $signed({1'b0, p2})   - $signed({1'b0, pavg});
  wire [31:0]        pavg_nx = pavg + 32'(d_pavg >>> 4);

  wire signed [32:0] d_noise = $signed({1'b0, pavg_nx}) - $signed({1'b0, noise});
  wire [31:0]        noise_nx = warmup_done ? noise + 32'(d_noise >>> 8)
                                            : noise + 32'(d_noise >>> 4);

  wire [34:0] noise_x8 = {noise, 3'b000};
  always_comb begin
    if (burst_thr != 0)          thr_on = burst_thr;
    else if (noise_x8[34:32] != 0) thr_on = 32'hFFFF_FFFF;
    else if (noise_x8[31:0] < 32'd64) thr_on = 32'd64;
    else                         thr_on = noise_x8[31:0];
  end

  wire burst_nx = burst_q ? !(pavg_nx < (thr_on >> 1)) : (pavg_nx > thr_on);

  wire signed [32:0] d_bpwr  = $signed({1'b0, pavg_nx}) - $signed({1'b0, burst_pwr});

  always_ff @(posedge clk) begin
    if (rst) begin
      pavg        <= '0;
      noise       <= 32'hFFFF_FFFF;
      warm_cnt    <= '0;
      warmup_done <= 1'b0;
      burst_q     <= 1'b0;
      out_valid   <= 1'b0;
      burst       <= 1'b0;
      burst_start <= 1'b0;
      burst_end   <= 1'b0;
      burst_len   <= '0;
      burst_peak  <= '0;
      burst_pwr   <= '0;
      out_dphi    <= '0;
    end
    else begin
      out_valid   <= v2;
      burst_start <= 1'b0;
      burst_end   <= 1'b0;
      if (v2) begin
        pavg     <= pavg_nx;
        out_dphi <= dphi2;
        if (!burst_q) begin
          noise <= noise_nx;
          if (!warmup_done) begin
            warm_cnt <= warm_cnt + 1'b1;
            if (warm_cnt == 11'd1023) warmup_done <= 1'b1;
          end
        end
        burst_q     <= burst_nx;
        burst       <= burst_nx;
        burst_start <= burst_nx && !burst_q;
        burst_end   <= !burst_nx && burst_q;

        if (burst_nx && !burst_q) begin        // перший відлік пакета
          burst_len  <= 32'd0;
          burst_peak <= 32'd0;
          burst_pwr  <= pavg_nx;
        end
        else if (burst_nx) begin
          burst_len <= burst_len + 1'b1;
          if (pavg_nx > burst_peak) burst_peak <= pavg_nx;
          burst_pwr <= burst_pwr + 32'(d_bpwr >>> 6);
        end
      end
    end
  end

endmodule
