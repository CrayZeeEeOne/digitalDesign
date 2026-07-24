module look_ahead #(
  parameter N = 16
)(
  input logic [N-1:0] a, b, 
  input logic cin,
  output logic cout,
  output logic [N-1:0] sum
);

  wire logic [N-1:0] p, g, c;

  always_comb begin
    c[0] = cin;

    for (int i = 0; i < N; i++) begin
       p[i] = a[i] ^ b[i];

       g[i] = a[i] & b[i];

       sum[i] = p[i] ^ c[i];

       c[i+1] = g[i] | (cin[i] & p[i]);
    end
  end

  assign cout = c[N-1];

endmodule