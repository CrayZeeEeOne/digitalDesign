module axi_mst (
  input logic aclk,
  input logic arstn,
  axi_if.write_mst mw_bus,
  axi_if.read_mst mr_bus
);

  
  always_ff @(posedge aclk or negedge arstn)
    if (!arstn) begin

    end
    else begin

    end
endmodule