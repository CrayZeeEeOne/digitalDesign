module axi_master #(
  parameter N = 8
)(
  input logic clk, n_rst, ready,
  output logic valid,
  output logic [N-1:0] data
);

  typedef enum logic {
    IDLE,
    TRANSFER
  } state_t;

  state_t current_state, next_state;
  
  always_ff @(posedge clk, negedge n_rst) begin
    if (!n_rst) begin
      current_state <= IDLE;
      valid <= 0;
      data <= 'x;
    end
    else begin
      current_state <= next_state;
      data <= data_next;
      valid <= valid_next;
    end 
  end

  logic [N-1:0] data_next;
  logic valid_next;

  always_comb begin
    next_state = current_state;

    data_next = data;
    valid_next = valid;

    case (current_state)
      IDLE: begin
        data_next = 4'b1011;
        valid_next = 1;
        next_state = TRANSFER;
      end
      TRANSFER: begin
        if (ready && valid) begin
          data_next = 'x;
          valid_next = 0;
          next_state = IDLE;
        end
        else
          next_state = TRANSFER;
      end
      
    endcase
    
  end

endmodule