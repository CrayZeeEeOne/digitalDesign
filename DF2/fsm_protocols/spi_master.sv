module spi_master #(
  parameter N = 4
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

  logic [N-1:0] tx_shift_reg, tx_shift_reg_next;
  logic [N-1:0] rx_shift_reg, rx_shift_reg_next;

  logic [N-1:0] bit_index, bit_index_next;

  logic mosi_next;

  logic sck_prev;

  always_ff @(posedge clk, posedge reset) begin
    if (reset) begin
      current_state <= IDLE;
      tx_shift_reg <= 0;
      rx_shift_reg <= 0;
      bit_index <= 0;
      sck_prev <= 0;
      mosi <= 0;
    end
    else begin
      current_state <= next_state;
      tx_shift_reg <= tx_shift_reg_next;
      rx_shift_reg <= rx_shift_reg_next;
      bit_index <= bit_index_next;
      sck_prev <= sck;
      mosi <= mosi_next;
    end
  end
  
  logic [1:0] cnt;
  // sck = 1/2 clk
  always_ff @(posedge clk, posedge reset) begin
    if (reset) begin
      cnt <= 2'd0;
      sck <= 0;
    end
    else if (cnt == 2'd1 & ~cs) begin
      cnt <= 2'd0;
      sck <= ~sck;
    end
    else if (~cs) begin
      cnt <= cnt + 1'b1;
      sck <= 0;
    end
  end

  always_comb begin
    next_state = current_state;

    tx_shift_reg_next = tx_shift_reg;
    rx_shift_reg_next = rx_shift_reg;
    bit_index_next = bit_index;
    mosi_next = mosi;

    done = 0;
    cs = 1;

    case (current_state)
      IDLE:
        if (start) begin
          cs = 0;
          tx_shift_reg_next = data;
          bit_index_next = N+1;
          next_state = RECORD;
        end
        else next_state = IDLE;
      RECORD: begin
        cs = 0;
        if (sck & ~sck_prev) begin //sck rising edge
          rx_shift_reg_next[N-1] = miso;
          mosi_next = tx_shift_reg[0];
          bit_index_next--;
          next_state = CHECK;
        end
      end
      SHIFT: begin
        cs = 0;
        if (~sck & sck_prev) begin //sck falling edge
          tx_shift_reg_next = tx_shift_reg >> 1;
          rx_shift_reg_next = rx_shift_reg >> 1;
          next_state = RECORD;
        end
      end
      CHECK: begin
        if (bit_index == 0) begin
          done = 1;
          cs = 1;
          next_state = IDLE;
        end
        else begin
          cs = 0;
          next_state = SHIFT;
        end
      end
    endcase
  end

endmodule