//==============================================================================
// demod_cic3 -- CIC-децисатор 3-го порядку для двох каналів (I та Q).
//
// Інтегратори працюють на вхідній швидкості (32 біти з переповненням --
// для CIC це нормально, доки кінцевий результат влазить, тобто
// 16 + 3*log2(R) <= 32  ->  R <= 32). Гребінчасті фільтри -- на вихідній.
// Підсилення R^3 компенсується зсувом `shift` = 3*log2(R); результат
// насичується до 16 біт.
//
// decim може бути будь-яким 2..32 (для не степенів двійки зсув приблизний).
//==============================================================================
module demod_cic3 (
  input  logic               clk,
  input  logic               rst,

  input  logic [7:0]         decim,     // коефіцієнт децимації R
  input  logic [4:0]         shift,     // зсув праворуч на виході

  input  logic               in_valid,
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,

  output logic               out_valid,
  output logic signed [15:0] out_i,
  output logic signed [15:0] out_q
);

  //------------------------------------------------------ інтегратори ----
  logic signed [31:0] ii1, ii2, ii3, qi1, qi2, qi3;
  logic [7:0]         cnt;
  logic               dec_strobe;        // останній відлік групи прийнято

  always_ff @(posedge clk) begin
    if (rst) begin
      ii1 <= '0; ii2 <= '0; ii3 <= '0;
      qi1 <= '0; qi2 <= '0; qi3 <= '0;
      cnt <= '0;
      dec_strobe <= 1'b0;
    end
    else begin
      dec_strobe <= 1'b0;
      if (in_valid) begin
        ii1 <= ii1 + 32'(in_i);
        ii2 <= ii2 + ii1;
        ii3 <= ii3 + ii2;
        qi1 <= qi1 + 32'(in_q);
        qi2 <= qi2 + qi1;
        qi3 <= qi3 + qi2;
        if (cnt >= decim - 1'b1) begin
          cnt        <= '0;
          dec_strobe <= 1'b1;
        end
        else
          cnt <= cnt + 1'b1;
      end
    end
  end

  //------------------------------------------------------- гребінці -------
  // Три послідовні різниці, виконуються за один такт на dec_strobe.
  logic signed [31:0] ic1, ic2, ic3, qc1, qc2, qc3;   // попередні значення
  logic signed [31:0] di1, di2, di3, dq1, dq2, dq3;
  logic               comb_valid;

  assign di1 = ii3 - ic1;  assign di2 = di1 - ic2;  assign di3 = di2 - ic3;
  assign dq1 = qi3 - qc1;  assign dq2 = dq1 - qc2;  assign dq3 = dq2 - qc3;

  logic signed [31:0] yi, yq;

  always_ff @(posedge clk) begin
    if (rst) begin
      ic1 <= '0; ic2 <= '0; ic3 <= '0;
      qc1 <= '0; qc2 <= '0; qc3 <= '0;
      comb_valid <= 1'b0;
    end
    else begin
      comb_valid <= dec_strobe;
      if (dec_strobe) begin
        ic1 <= ii3; ic2 <= di1; ic3 <= di2;
        qc1 <= qi3; qc2 <= dq1; qc3 <= dq2;
        yi  <= di3 >>> shift;
        yq  <= dq3 >>> shift;
      end
    end
  end

  //------------------------------------------------------- насичення -----
  function automatic logic signed [15:0] sat16(input logic signed [31:0] v);
    if (v > 32'sd32767)       return 16'sd32767;
    else if (v < -32'sd32768) return -16'sd32768;
    else                      return v[15:0];
  endfunction

  always_ff @(posedge clk) begin
    out_valid <= comb_valid && !rst;
    out_i     <= sat16(yi);
    out_q     <= sat16(yq);
  end

endmodule
