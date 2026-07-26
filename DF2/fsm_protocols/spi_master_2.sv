module spi_master #(
  parameter int N = 4
)(
  input logic clk, reset, start, miso,
  input logic [N-1:0] data,
  output logic mosi, done, sck, cs
);

  typedef enum logic [1:0] { 
    IDLE,
    RECORD,
    SHIFT,
    CHECK
  } state_t;
  
  state_t current_state, next_state;

  logic [N-1:0] shift_reg, shift_reg_next;

  logic [N-1:0] bit_index, bit_index_next;

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      current_state <= IDLE;
      shift_reg <= 0;
      bit_index <= 0;
    end
    else begin
      current_state <= next_state;
      shift_reg <= shift_reg_next;
      bit_index <= bit_index_next;
    end
  end

  always_comb begin
    next_state = current_state;
    shift_reg_next = shift_reg;
    bit_index_next = bit_index;
    
    done = 0;
    sck = 1;
    cs = 1;

    case (current_state)
      IDLE: begin
        if (start) next_state = RECORD;
        else next_state = IDLE;
      end
      RECORD: begin
        shift_reg_next = data;
        bit_index_next = N;
        next_state = SHIFT;
      end
      SHIFT: begin
        cs = 0;
        sck = 0;
        shift_reg_next = shift_reg >> 1;
        bit_index_next = bit_index - 1;

        next_state = CHECK;
      end
      CHECK: begin
        cs = 0;
        if (bit_index == 0) begin
            done = 1;
            next_state = IDLE;
        end
        else next_state = SHIFT;
      end
    endcase
  end

  assign mosi = shift_reg[0];
endmodule