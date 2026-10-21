//==============================================================================
// iq_stream_fifo -- синхронний FIFO з виходом "перше слово одразу" (FWFT).
//
// Пам'ять виводиться в BRAM: читання синхронне за адресою rd_ptr, слово
// переходить у вихідний регістр, щойно той вільний. Пропускна здатність --
// одне слово за такт.
//
//   level  -- скільки слів усередині (пам'ять + вихідний регістр)
//   wr_en при full ігнорується; переповнення фіксує верхній рівень.
//==============================================================================
module iq_stream_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 1024                 // степінь двійки
)(
  input  logic                    clk,
  input  logic                    rst,       // синхронний, активний 1 (також flush)

  input  logic                    wr_en,
  input  logic [WIDTH-1:0]        wr_data,
  output logic                    full,

  output logic                    m_valid,
  input  logic                    m_ready,
  output logic [WIDTH-1:0]        m_data,

  output logic                    empty,     // нічого немає навіть у вихідному регістрі
  output logic [$clog2(DEPTH):0]  level
);

  localparam int PW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [PW:0]      wr_ptr, rd_ptr;         // зайвий біт -- для full

  wire [PW:0] mem_count = wr_ptr - rd_ptr;
  wire        mem_empty = (mem_count == '0);
  // повний -- за загальним рівнем (пам'ять + вихідний регістр), тож місткість
  // рівно DEPTH слів, як і рахують PUSHED/DROPPED
  assign      full      = (level >= (PW+1)'(DEPTH));

  wire do_write = wr_en && !full;
  // вихідний регістр вільний або саме звільняється -> витягуємо наступне слово
  wire out_free = !m_valid || m_ready;
  wire do_read  = out_free && !mem_empty;

  always_ff @(posedge clk) begin
    if (do_write) mem[wr_ptr[PW-1:0]] <= wr_data;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_ptr  <= '0;
      rd_ptr  <= '0;
      m_valid <= 1'b0;
    end
    else begin
      if (do_write) wr_ptr <= wr_ptr + 1'b1;
      if (out_free) begin
        m_valid <= !mem_empty;
        if (!mem_empty) rd_ptr <= rd_ptr + 1'b1;
      end
    end
  end

  // Синхронне читання BRAM; дані дійсні разом з m_valid у наступному такті.
  always_ff @(posedge clk) begin
    if (do_read) m_data <= mem[rd_ptr[PW-1:0]];
  end

  assign empty = mem_empty && !m_valid;
  assign level = mem_count + (m_valid ? 1'b1 : 1'b0);

endmodule
