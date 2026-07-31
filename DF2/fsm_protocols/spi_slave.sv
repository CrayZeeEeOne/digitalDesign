module spi_slave #(
  parameter N = 4 
)(
  input logic start, mosi, cs, clk, sck, reset,
  output logic miso, done
);
  
  typedef enum logic [1:0] {
    IDLE,
    RECORD,
    SHIFT
  } state_t;

  state_t current_state, next_state;

  logic [N-1:0] rx_shift_reg, rx_shift_reg_next; 
  logic [N-1:0] tx_shift_reg, tx_shift_reg_next;

  logic [$clog2(N+1):0] bit_index, bit_index_next;

  logic miso_next;

  logic sck_prev;

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      current_state <= IDLE;
      rx_shift_reg <= 0;
      tx_shift_reg <= 4'b1101;
      bit_index <= 0;
      sck_prev <= 0;
      miso <= 0;
    end
    else begin
      current_state <= next_state;
      tx_shift_reg <= tx_shift_reg_next;
      rx_shift_reg <= rx_shift_reg_next;
      bit_index <= bit_index_next;
      miso <= miso_next;
      sck_prev <= sck;
    end
  end

  always_comb begin
    next_state = current_state;

    tx_shift_reg_next = tx_shift_reg;
    rx_shift_reg_next = rx_shift_reg;
    bit_index_next = bit_index;
    miso_next = miso;

    done = 0;

    case (current_state)
      IDLE:
        if (start) begin 
          bit_index_next = N;
          miso_next = tx_shift_reg[0];
          next_state = RECORD;
        end
        else
          next_state = IDLE;
      RECORD: begin
        if (sck && !sck_prev && !cs) begin
          rx_shift_reg_next[N-1] = mosi;
          next_state = SHIFT;
        end
      end
      SHIFT: begin
        if (!sck && sck_prev && !cs) begin
          tx_shift_reg_next = tx_shift_reg >> 1;
          rx_shift_reg_next = rx_shift_reg >> 1;
          bit_index_next = bit_index - 1;
          if (bit_index == 1) begin
            done = 1;
            next_state = IDLE;
          end
          else begin
            miso_next = tx_shift_reg[1];
            next_state = RECORD;
          end
        end
      end
    endcase
  end
endmodule