module mult #(
    parameter N = 4
)(
  input logic [N-1:0] a, b,
  output logic [N*2-1:0] p
);

  logic c;
  logic [N-1:0] acc, q;

  always_comb begin
    c = 0;
    acc = 0;
    q = b;
    for (int i = 0; i < N; i++) begin
        if (q[0]) 
          {c, acc} = {1'b0, acc} + {1'b0, a};
        {c, acc, q} = {c, acc, q} >> 1;
    end
    p = {acc, q};
  end
endmodule