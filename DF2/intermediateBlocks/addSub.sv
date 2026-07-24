module addSub #(
  parameter N = 16
)(
  input logic [N-1:0] a, b,
  input logic sub,
  output logic [N-1:0] diff,
  output logic borrow
);
  always_comb begin
    case(sub)
      0: begin
        diff = a ^ b;
        borrow = a & b;
      end
      1: begin
        diff = a ^ b;
        borrow = ~a & b;
      end
    endcase
  end 
endmodule