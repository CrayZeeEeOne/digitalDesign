//==============================================================================
// demod_cordic_atan2 -- конвеєрний CORDIC у режимі vectoring: кут вектора
// (x, y) у форматі 16 біт, де 2^15 = pi (тобто повний оберт = 2^16, кут
// природно "загортається" за модулем 2*pi).
//
// Вхід: знакові W-бітні x, y. Для точності подавайте нормалізовані значення
// (|max| у верхніх бітах) -- це робить demod_discriminator.
//
// Латентність: ITER + 1 тактів. Супутні дані aux проходять з тією ж
// затримкою, щоб результат лишався вирівняним із джерелом.
//==============================================================================
module demod_cordic_atan2 #(
  parameter int W     = 18,
  parameter int ITER  = 16,
  parameter int AUX_W = 32
)(
  input  logic                    clk,
  input  logic                    rst,

  input  logic                    in_valid,
  input  logic signed [W-1:0]     in_x,
  input  logic signed [W-1:0]     in_y,
  input  logic [AUX_W-1:0]        in_aux,

  output logic                    out_valid,
  output logic signed [15:0]      out_angle,
  output logic [AUX_W-1:0]        out_aux
);

  // atan(2^-i) / pi * 2^15, i = 0..15 (tools/demod_model.py рахує так само)
  localparam logic [15:0] ATAN [0:15] = '{
    16'd8192, 16'd4836, 16'd2555, 16'd1297, 16'd651, 16'd326, 16'd163, 16'd81,
    16'd41,   16'd20,   16'd10,   16'd5,    16'd3,   16'd1,   16'd1,   16'd0
  };

  localparam int IW = W + 2;                  // запас на зростання 1.647

  logic                 v   [0:ITER];
  logic signed [IW-1:0] x   [0:ITER];
  logic signed [IW-1:0] y   [0:ITER];
  logic signed [15:0]   z   [0:ITER];
  logic [AUX_W-1:0]     aux [0:ITER];

  //------------------------------------------- стадія 0: у праву півплощину
  always_ff @(posedge clk) begin
    v[0]   <= in_valid && !rst;
    aux[0] <= in_aux;
    if (in_x < 0) begin
      x[0] <= -IW'(in_x);
      y[0] <= -IW'(in_y);
      z[0] <= 16'h8000;                        // +pi (== -pi за модулем)
    end
    else begin
      x[0] <= IW'(in_x);
      y[0] <= IW'(in_y);
      z[0] <= 16'h0000;
    end
  end

  //------------------------------------------------- стадії 1..ITER -------
  genvar i;
  generate
    for (i = 0; i < ITER; i++) begin : g_it
      always_ff @(posedge clk) begin
        v[i+1]   <= v[i];
        aux[i+1] <= aux[i];
        if (y[i] >= 0) begin
          x[i+1] <= x[i] + (y[i] >>> i);
          y[i+1] <= y[i] - (x[i] >>> i);
          z[i+1] <= z[i] + ATAN[i];
        end
        else begin
          x[i+1] <= x[i] - (y[i] >>> i);
          y[i+1] <= y[i] + (x[i] >>> i);
          z[i+1] <= z[i] - ATAN[i];
        end
      end
    end
  endgenerate

  assign out_valid = v[ITER];
  assign out_angle = z[ITER];
  assign out_aux   = aux[ITER];

endmodule
