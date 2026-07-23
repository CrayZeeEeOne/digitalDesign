module traffic_fsm (
  input logic clk, reset, Ta, Tb,
  output logic [1:0] La, Lb

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
        if (~Ta) next_state = s1;
        else if (Ta) next_state = s0;
      s1:
        next_state = s2;
      s2:
        if (~Tb) next_state = s3;
        else if (Tb) next_state = s2;
      s3:
        next_state = s0;
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
    //default values
    La = 2'b00; 
    Lb = 2'b10;

    case (current_state)
      s0: begin
        La = 2'b00; Lb = 2'b10;
      end
      s1: begin
        La = 2'b01; Lb = 2'b10;
      end
      s2: begin
        La = 2'b10; Lb = 2'b00;
      end
      s3: begin
        La = 2'b10; Lb = 2'b10; 
      end
      default: begin
        La = 2'b00; Lb = 2'b10;
      end
    endcase
  end
  
endmodule


  // assign next_state[1] = s1 ^ s0;
  // assign next_state[0] = (~s1 & ~s0 & ~Ta) | (s1 & ~s0 & ~Tb);