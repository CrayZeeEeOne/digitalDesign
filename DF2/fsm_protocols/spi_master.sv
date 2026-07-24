// module spi_master #(
//   parameter N = 4 
// )(
//   input logic clk, reset, start, miso,
//   input logic [N-1:0] data,
//   output logic mosi, done, sck, cs
// );
//   typedef enum logic [1:0] {
//     s0 = 2'b00,
//     s1 = 2'b01,
//     s2 = 2'b10,
//     s3 = 2'b11
//   } state_t;

//   state_t current_state, next_state;

//   logic [N-1:0] shift_reg;

//   always_ff @(posedge clk or negedge reset) begin
//     if (!reset) begin
//       shift_reg = 0;
//       mosi = 0;
//       done = 0;
//       cs = 0;
//       sck = 0;
//     end
    
//   end


// endmodule