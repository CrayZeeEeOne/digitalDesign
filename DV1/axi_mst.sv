module axi_mst (
  input logic aclk,
  input logic arstn,
  axi_if.write_mst mw_bus,
  axi_if.read_mst mr_bus,

  //write command
  input logic wcmd_valid,
  output logic wcmd_ready,
  input logic [mr_bus.ADDR_BW-1:0] wcmd_addr,
  input logic [7:0] wcmd_len,
  input logic [2:0] wcmd_size,
  input logic [1:0] wcmd_burst,
  input logic [mr_bus.ID_BW-1:0] wcmd_id,

  //write stream
  input logic wd_valid,
  output logic wd_ready,
  input logic [mr_bus.DATA_BW-1:0] wd_data,
  input logic [mr_bus.STRB_BW-1:0] wd_strb,

  //write status
  output logic wsts_valid,
  input logic wsts_ready,
  output logic [1:0] wsts_resp,
  output logic [mr_bus.ID_BW-1:0] wsts_id,

  //read command
  input logic rcmd_valid,
  output logic rcmd_ready,
  input logic [mr_bus.ADDR_BW-1:0] rcmd_addr,
  input logic [7:0] rcmd_len,
  input logic [2:0] rcmd_size,
  input logic [1:0] rcmd_burst,
  input logic [mr_bus.ID_BW-1:0] rcmd_id,


  //read stream
  output logic rd_valid,
  input logic rd_ready,
  output logic [mr_bus.DATA_BW-1:0] rd_data,
  output logic rd_last,
  output logic [1:0] rd_resp
);

  localparam ADDR_BW = mr_bus.ADDR_BW;
  localparam DATA_BW = mr_bus.DATA_BW;
  localparam ID_BW = mr_bus.ID_BW;
  
  //handshake
  wire aw_hs = mw_bus.awvalid && mw_bus.awready; 
  wire w_hs = mw_bus.wvalid && mw_bus.wready; 
  wire b_hs = mw_bus.bvalid && mw_bus.bready; 
  wire ar_hs = mr_bus.arvalid && mr_bus.arready;
  wire r_hs = mr_bus.rvalid && mr_bus.rready;

  wire wcmd_hs = wcmd_valid && wcmd_ready;
  wire rcmd_hs = rcmd_valid && rcmd_ready;
  wire wsts_hs = wsts_valid && wsts_ready;

  //write
  typedef enum logic [1:0] {
    W_IDLE, //recieve cmd
    W_XFER, //aw & w
    W_RESP //waiting bvalid
  } wr_state_t;

  wr_state_t wr_state, wr_next;

  logic [ADDR_BW-1:0] w_addr;
  logic [7:0] w_len;
  logic [2:0] w_size;
  logic [1:0] w_burst;
  logic [ID_BW-1:0] w_id;
  logic [7:0] w_cnt; //beats sent
  logic aw_sent; //slave aw received

  wire w_last_beat = (w_cnt == w_len);
  
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) wr_state <= W_IDLE;
    else wr_state <= wr_next;
  end
  
  always_comb begin
    wr_next = wr_state;
    case (wr_state)
      W_IDLE: if (wcmd_hs) wr_next = W_XFER;
      W_XFER: if (w_hs && w_last_beat && (aw_sent || aw_hs))
        wr_next = W_RESP;
      W_RESP: if (wsts_hs) wr_next = W_IDLE;
      default: wr_next = W_IDLE;
    endcase
  end

  //cmd context
  always_ff @(posedge aclk) begin
    if (wcmd_hs) begin
      w_addr <= wcmd_addr;
      w_len <= wcmd_len;
      w_size <= wcmd_size;
      w_burst <= wcmd_burst;
      w_id <= wcmd_id;
    end
  end

  //beats conunter
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) w_cnt <= '0;
    else if (wcmd_hs) w_cnt <= '0;
    else if (w_hs) w_cnt <= w_cnt + 8'd1;
  end

  //aw sent once per transaction
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) aw_sent <= 1'b0;
    else if (wcmd_hs) aw_sent <= 1'b0;
    else if (aw_hs) aw_sent <= 1'b1;
  end

  logic [1:0] bresp_reg;
  logic [ID_BW-1:0] bid_reg;

  always_ff @(posedge aclk) begin
    if (b_hs) begin
      bresp_reg <= mw_bus.bresp;
      bid_reg <= mw_bus.bid;
    end
  end

  logic b_got;

  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) b_got <= 1'b0;
    else if (wsts_hs) b_got <= 1'b0;
    else if (b_hs) b_got <= 1'b1;
  end

  //outputs

  assign wcmd_ready = (wr_state == W_IDLE);

  assign mw_bus.awvalid = (wr_state == W_XFER) && !aw_sent;
  assign mw_bus.awid = w_id;
  assign mw_bus.awaddr = w_addr;
  assign mw_bus.awlen = w_len;
  assign mw_bus.awsize = w_size;
  assign mw_bus.awburst = w_burst;
  assign mw_bus.awlock = 1'b0;
  assign mw_bus.awcache = 4'b0000;
  assign mw_bus.awprot = 3'b000;
  assign mw_bus.awqos = 4'b0000;

  assign mw_bus.wvalid = (wr_state == W_XFER) && wd_valid;
  assign mw_bus.wdata = wd_data;
  assign mw_bus.wstrb = wd_strb;
  assign mw_bus.wlast = w_last_beat;
  assign wd_ready = (wr_state == W_XFER) && mw_bus.wready;

  assign mw_bus.bready = !b_got;

  assign wsts_valid = (wr_state == W_RESP) && b_got;
  assign wsts_resp = bresp_reg;
  assign wsts_id = bid_reg;

  //read
  typedef enum logic [1:0] {
    R_IDLE,
    R_ADDR,
    R_DATA
  } rd_state_t;

  rd_state_t rd_state, rd_next;

  logic [ADDR_BW-1:0] r_addr;
  logic [7:0] r_len;
  logic [2:0] r_size;
  logic [1:0] r_burst;
  logic [ID_BW-1:0] r_id;

  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) rd_state <= R_IDLE;
    else rd_state <= rd_next;
  end

  always_comb begin
    rd_next = rd_state;
    case (rd_state)
      R_IDLE: if (rcmd_hs) rd_next = R_ADDR;
      R_ADDR: if (ar_hs) rd_next = R_DATA;
      R_DATA: if (r_hs && mr_bus.rlast) rd_next = R_IDLE;
      default: rd_next = R_IDLE;
    endcase
  end

  always_ff @(posedge aclk) begin
    if (rcmd_hs) begin
      r_addr <= rcmd_addr;
      r_len <= rcmd_len;
      r_size <= rcmd_size;
      r_burst <= rcmd_burst;
      r_id <= rcmd_id;
    end
  end 

  //ouputs
  assign rcmd_ready = (rd_state == R_IDLE);

  assign mr_bus.arvalid = (rd_state == R_ADDR);
  assign mr_bus.arid = r_id;
  assign mr_bus.araddr = r_addr;
  assign mr_bus.arlen = r_len;
  assign mr_bus.arsize = r_size;
  assign mr_bus.arburst = r_burst;
  assign mr_bus.arlock = 1'b0;
  assign mr_bus.arcache = 4'b0000;
  assign mr_bus.arprot = 3'b000;
  assign mr_bus.arqos = 4'b0000;

  assign rd_valid = (rd_state == R_DATA) && mr_bus.rvalid;
  assign rd_data = mr_bus.rdata;
  assign rd_last = mr_bus.rlast;
  assign rd_resp = mr_bus.rresp;
  assign mr_bus.rready = (rd_state == R_DATA) && rd_ready;

endmodule