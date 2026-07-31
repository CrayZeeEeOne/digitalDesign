module spi_master #(
    parameter N = 8
)(
    input  logic         clk,
    input  logic         reset,
    input  logic         start,
    input  logic         miso,
    input  logic [N-1:0] data,

    output logic         mosi,
    output logic         done,
    output logic         sck,
    output logic         cs
);

typedef enum logic [1:0] {
    IDLE,
    RECORD,
    SHIFT
} state_t;

state_t current_state, next_state;

logic [N-1:0] tx_shift_reg, tx_shift_reg_next;
logic [N-1:0] rx_shift_reg, rx_shift_reg_next;

logic [$clog2(N+1)-1:0] bit_index, bit_index_next;

logic mosi_next;
logic sck_prev;

//////////////////////////////////////////////////////////
// Registers
//////////////////////////////////////////////////////////

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        current_state <= IDLE;
        tx_shift_reg  <= '0;
        rx_shift_reg  <= '0;
        bit_index     <= '0;
        sck_prev      <= 1'b0;
        mosi          <= 1'b0;
    end
    else begin
        current_state <= next_state;
        tx_shift_reg  <= tx_shift_reg_next;
        rx_shift_reg  <= rx_shift_reg_next;
        bit_index     <= bit_index_next;
        sck_prev      <= sck;
        mosi          <= mosi_next;
    end
end

//////////////////////////////////////////////////////////
// SCK generator
//////////////////////////////////////////////////////////

logic cnt;

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        cnt <= 1'b0;
        sck <= 1'b0;
    end
    else if (!cs) begin
        cnt <= ~cnt;

        if (cnt)
            sck <= ~sck;
    end
    else begin
        cnt <= 1'b0;
        sck <= 1'b0;
    end
end

//////////////////////////////////////////////////////////
// FSM
//////////////////////////////////////////////////////////

always_comb begin

    next_state = current_state;

    tx_shift_reg_next = tx_shift_reg;
    rx_shift_reg_next = rx_shift_reg;
    bit_index_next    = bit_index;

    mosi_next = mosi;

    done = 0;
    cs   = 1;

    case (current_state)

    //////////////////////////////////////////////////////
    IDLE:
    //////////////////////////////////////////////////////
    begin
        if (start) begin
            cs = 0;

            tx_shift_reg_next = data;
            rx_shift_reg_next = '0;

            bit_index_next = N;

            mosi_next = data[0];

            next_state = RECORD;
        end
    end

    //////////////////////////////////////////////////////
    // Sample MISO on rising edge
    //////////////////////////////////////////////////////
    RECORD:
    begin
        cs = 0;

        if (sck && !sck_prev) begin
            rx_shift_reg_next[N-1] = miso;
            next_state = SHIFT;
        end
    end

    //////////////////////////////////////////////////////
    // Shift on falling edge
    //////////////////////////////////////////////////////
    SHIFT:
    begin
        cs = 0;

        if (!sck && sck_prev) begin

            tx_shift_reg_next = tx_shift_reg >> 1;
            rx_shift_reg_next = rx_shift_reg >> 1;

            bit_index_next = bit_index - 1;

            if (bit_index == 1) begin
                done = 1;
                cs = 1;
                next_state = IDLE;
            end
            else begin
                mosi_next = tx_shift_reg[1];
                next_state = RECORD;
            end
        end
    end

    endcase
end

endmodule