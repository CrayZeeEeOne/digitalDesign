module sequenceDetector ( //1011 
  input logic clk, reset, in_bit,
  output logic detected
);

typedef enum logic [1:0] {
  s0 = 2'b00,
  s1 = 2'b01,
  s2 = 2'b10,
  s3 = 2'b11
} state_t;

state_t current_state, next_state;

always_comb begin
  next_state = current_state;

  case (current_state)
    s0:
      if (~in_bit) next_state = s0;
      else if (in_bit) next_state = s1;
    s1:
      if (in_bit) next_state = s1;
      else if (~in_bit) next_state = s2;
    s2:
      if (~in_bit) next_state = s0;
      else if (in_bit) next_state = s3;
    s3:
      if (~in_bit) next_state = s2;
      else if (in_bit) next_state = s0;
    default: 
      next_state = s0;
  endcase
end

always_ff @(posedge clk or negedge reset) begin
  if (!reset)
    current_state <= s0;
  else
    current_state <= next_state;
end

always_comb begin
  detected = 0;

  case (current_state) 
    s0:
      detected = 0;
    s1:
      detected = 0;
    s2:
      detected = 0;
    s3: begin
      if (in_bit) detected = 1;
      else detected = 0;
    end
    default:
      detected = 0;
  endcase   
end

endmodule