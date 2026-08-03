module axi_slv #(
  parameter MEM_DEPTH = 1024
)(
  input logic aclk,
  input logic arstn,
  axi_if.read_slv sr_bus,
  axi_if.write_slv sw_bus
);
  
  localparam ADDR_BW = sr_bus.ADDR_BW;
  localparam DATA_BW = sr_bus.DATA_BW;
  localparam ID_BW = sr_bus.ID_BW;
  localparam STRB_BW = sr_bus.STRB_BW;
  localparam ADDR_LSB = $clog2(STRB_BW);
  localparam MEM_AW = $clog2(MEM_DEPTH);

  localparam logic [1:0] RESP_OKAY = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  typedef enum logic [1:0] {
    READ_IDLE, //чекаємо адресу
    R //віддаємо beat-и поки не rlast
  } read_state_t;

  read_state_t read_state, next_read_state;

  wire ar_hs = sr_bus.arvalid && sr_bus.arready;
  wire r_hs = sr_bus.rvalid && sr_bus.rready;

  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn)
      read_state <= READ_IDLE;
    else
      read_state <= next_read_state;
  end 
   
  always_comb begin
    next_read_state = read_state;
    case (read_state)
      READ_IDLE:
        if (ar_hs)
        next_read_state = R;
      R:
        if (r_hs && sr_bus.rlast)
        next_read_state = READ_IDLE;
      default:
        next_read_state = READ_IDLE;
    endcase
  end

  //burst
  function automatic logic [ADDR_BW-1:0] next_addr (
    input logic [ADDR_BW-1:0] curr,
    input logic [ADDR_BW-1:0] start,
    input logic [2:0] size,
    input logic [7:0] len,
    input logic [1:0] burst
  );
   
    logic [ADDR_BW-1:0] step, total, aligned, wrap_lo;

    step = ADDR_BW'(1) << size;
    total = (ADDR_BW'(len) + ADDR_BW'(1)) << size;
    aligned = (curr >> size) << size;

    case (burst)
    //fixed
    2'b00:
      next_addr = curr;
    //wrap
    2'b10: begin
      wrap_lo = start & ~(total - ADDR_BW'(1));
      next_addr = aligned + step;
      if (next_addr == wrap_lo + total) next_addr = wrap_lo;
    //incr
    default:
      next_addr = aligned + step;
    end
    endcase
  endfunction
   
  //transaction

  logic [ID_BW-1:0] ar_id;
  logic [7:0] ar_len;
  logic [2:0] ar_size;
  logic [1:0] ar_burst;
  logic [ADDR_BW-1:0] ar_addr;
  logic [ADDR_BW-1:0] ar_start;
  logic [7:0] r_cnt;
  logic dec_err;

  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) begin
      r_cnt <= '0;
      dec_err <= 1'b0;
    end
    else if (ar_hs) begin
      ar_id <= sr_bus.arid;
      ar_len <= sr_bus.arlen;
      ar_size <= sr_bus.arsize;
      ar_burst <= sr_bus.arburst;
      ar_addr <= sr_bus.araddr;
      ar_start <= sr_bus.araddr;
      r_cnt <= '0;
      dec_err <= (sr_bus.araddr >> ADDR_LSB) >= MEM_DEPTH;
    end
    else if (r_hs) begin
      ar_addr <= next_addr(ar_addr, ar_start, ar_size, ar_len, ar_burst);
      r_cnt <= r_cnt + 8'b1;
    end
  end

  //memory
  logic [DATA_BW-1:0] mem [0:MEM_DEPTH-1];

  wire [MEM_AW-1:0] r_idx = ar_addr[ADDR_LSB +: MEM_AW];
                  //[addr_lsb + mem_aw - 1 : addr_lsb]
  
  //outputs
  assign sr_bus.arready = (read_state == READ_IDLE);
  assign sr_bus.rvalid = (read_state == R);
  assign sr_bus.rdata = dec_err ? '0 : mem[r_idx];
  assign sr_bus.rresp = dec_err ? RESP_SLVERR : RESP_OKAY;
  assign sr_bus.rlast = (r_cnt == ar_len);
  assign sr_bus.rid = ar_id;

  //protocol check

  assert property (@(posedge aclk) disable iff (!arstn)
    (sr_bus.rvalid && !sr_bus.rready)
      |=> sr_bus.rvalid && $stable(sr_bus.rdata) && $stable(sr_bus.rlast))
    else $error("R-channel non stable");
 
  assert property (@(posedge aclk) disable iff (!arstn)
    ar_hs |-> ((sr_bus.araddr & 12'hFFF)
               + ((sr_bus.arlen + 1) << sr_bus.arsize)) <= 13'h1000)
    else $error("AR: burst over 4 KB");
 
  assert property (@(posedge aclk) disable iff (!arstn)
    (ar_hs && sr_bus.arburst == 2'b10)
      |-> sr_bus.arlen inside {8'd1, 8'd3, 8'd7, 8'd15})
    else $error("AR: non valid lengh for wrap-burst");


  typedef enum logic [1:0] {
    WRITE_IDLE, //чекаємо awready та wready
    B //віддаємо bresp
  } write_state_t;

  write_state_t write_state, next_write_state;
   
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) begin
      write_state <= WRITE_IDLE;
    end
    else
      write_state <= next_write_state;
  end 




  always_comb begin
    next_write_state = write_state; 
    case (write_state)
      WRITE_IDLE:
      B:
      default:
        next_write_state = WRITE_IDLE;
    endcase
  end

endmodule