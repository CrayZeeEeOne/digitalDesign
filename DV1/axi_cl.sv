module axi_cl (
  input logic [N-1:0] window;
  input logic [1:0] config_select;
  output logic pixel;
);

  typedef enum logic [1:0] {
    MIN = 2'b00,
    MAX = 2'b01,
    MEDIAN = 2'b10,
    SOBEL = 2'b11
  } filter;

  //sobel cores
  int Gx [0:8] = '{
    -1, 0, +1,
    -2, 0, +2,
    -1, 0, +1
  };
  int Gy [0:8] = '{
    -1, -2, -1,
    0, 0, 0,
    +1, +2, +1
  };
  
endmodule
  