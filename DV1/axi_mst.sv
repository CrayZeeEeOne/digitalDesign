module axi_mst #(
  parameter int PIX_BW = 8
)(
  input logic aclk,
  input logic arstn,
  axi_if.write_mst mw_bus,
  axi_if.read_mst mr_bus,

  input logic start,
  input logic [mr_bus.ADDR_BW-1:0] src_addr,
  input logic [mr_bus.ADDR_BW-1:0] dst_addr,
  input logic [1:0] cfg_select,
  output logic busy,
  output logic done,
  output logic err
);

  localparam ADDR_BW = mr_bus.ADDR_BW;
  localparam DATA_BW = mr_bus.DATA_BW;
  localparam ID_BW = mr_bus.ID_BW;
  localparam STRB_BW = DATA_BW/8;

  localparam logic [1:0] BURST_INCR = 2'b01;
  localparam logic [2:0] BEAT_SIZE = 3'($clog2(STRB_BW));
  localparam logic [7:0] WIN_LEN = 8'd8;
  
  //handshake
  wire aw_hs = mw_bus.awvalid && mw_bus.awready; 
  wire w_hs = mw_bus.wvalid && mw_bus.wready; 
  wire b_hs = mw_bus.bvalid && mw_bus.bready; 
  wire ar_hs = mr_bus.arvalid && mr_bus.arready;
  wire r_hs = mr_bus.rvalid && mr_bus.rready;

  //fsm
  typedef enum logic [2:0] {
    IDLE,
    R_ADDR,
    R_DATA,
    W_XFER,
    W_RESP,
    DONE
  } state_t;

  state_t current_state, next_state;

  logic aw_sent, w_sent;   
  
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) current_state <= W_IDLE;
    else current_state <= next_state;
  end
  
  always_comb begin
    next_state = current_state;
    case (current_state)
      IDLE: if (start) next_state = R_ADDR;
      R_ADDR: if (ar_hs) next_state = R_DATA;
      R_DATA: if (r_hs && mr_bus.rlast) next_state = W_XFER;
      W_XFER: if ((aw_sent || aw_hs) && (w_sent || w_hs)) next_state = W_RESP;
      W_RESP: if (b_hs) next_state = DONE;
      DONE: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  logic [ADDR_BW-1:0] src_reg, dst_reg;
  logic [1:0] cfg_reg;

  always_ff @(posedge aclk) begin
    if (current_state == IDLE && start) begin
      src_reg = src_addr;
      dst_reg = dst_addr;
      cfg_reg = cfg_select;
    end
  end

  logic [PIX_BW-1:0] win [0:8];
  logic [3:0] beat_cnt;
  
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) beat_cnt <= '0;
    else if (current_state == IDLE) beat_cnt <= '0;
    else if (r_hs) beat_cnt <= beat_cnt + 4'd1;
  end

  always_ff @(posedge aclk) begin
    if (r_hs && (beat_cnt < 4'd9))
      win[beat_cnt] <= mr_bus.rdata[PIX_BW-1:0];
  end

  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) begin
      aw_sent <= 1'b0;
      w_sent <= 1'b0;
    end
    else if (current_state == R_DATA) begin
      aw_sent <= 1'b0;
      w_sent <= 1'b0;
    end
    else begin
      if (aw_hs) aw_sent <= 1'b1;
      if (w_hs) w_sent <= 1'b1;
    end
  end

  //error
  always_ff @(posedge aclk or negedge arstn) begin
    if (!arstn) err <= 1'b0;
    else if (current_state == IDLE && start) err <= 1'b0;
    else if (r_hs && (mr_bus.rresp != 2'b00)) err <= 1'b1;
    else if (b_hs && (mw_bus.bresp != 2'b00) err <= 1'b1;
  end

  //cl (filter)
  logic [PIX_BW-1:0] filt_pix;

  axi_cl #(.PIX_BW(PIX_BW)) u_cl (
    .i_win (win),
    .i_cfg (cfg_reg),
    .o_pix (filt_pix)
  );

  //outputs

  assign busy = (current_state != IDLE);
  assign done = (current_state == DONE);
  
  assign mr_bus.arvalid = (current_state == R_ADDR);
  assign mr_bus.arid = '0;
  assign mr_bus.araddr = src_addr;
  assign mr_bus.arlen = WIN_LEN;
  assign mr_bus.arsize = BEAT_SIZE;
  assign mr_bus.arburst = BURST_INCR;
  assign mr_bus.arlock = 1'b0;
  assign mr_bus.arcache = 4'b0000;
  assign mr_bus.arprot = 3'b000;
  assign mr_bus.arqos = 4'b0000;
  assign mr_bus.rready = (state == R_DATA);

  assign mw_bus.awvalid = (current_state == W_XFER) && !aw_sent;
  assign mw_bus.awid = '0;
  assign mw_bus.awaddr = dst_addr;
  assign mw_bus.awlen = 8'b0;
  assign mw_bus.awsize = BEAT_SIZE;
  assign mw_bus.awburst = BURST_INCR;
  assign mw_bus.awlock = 1'b0;
  assign mw_bus.awcache = 4'b0000;
  assign mw_bus.awprot = 3'b000;
  assign mw_bus.awqos = 4'b0000;

  assign mw_bus.wvalid = (current_state == W_XFER) && !w_sent;
  assign mw_bus.wdata = DATA_BW'(filt_pix);
  assign mw_bus.wstrb = '1;
  assign mw_bus.wlast = 1'b1;

  assign mw_bus.bready = (state == W_RESP);

endmodule