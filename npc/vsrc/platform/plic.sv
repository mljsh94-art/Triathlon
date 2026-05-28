module plic (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       source_pending_i,
    input  logic [2:0] source_priority_i,
    input  logic       enable_i,
    input  logic [2:0] threshold_i,
    input  logic       claim_i,
    input  logic       complete_i,
    output logic       irq_o,
    output logic [31:0] claim_id_o
);

  logic pending_q;
  logic claimed_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
      claimed_q <= 1'b0;
    end else begin
      if (source_pending_i && !claimed_q) begin
        pending_q <= 1'b1;
      end
      if (claim_i && pending_q && enable_i && (source_priority_i > threshold_i)) begin
        pending_q <= 1'b0;
        claimed_q <= 1'b1;
      end
      if (complete_i) begin
        claimed_q <= 1'b0;
      end
    end
  end

  assign irq_o = pending_q && enable_i && (source_priority_i > threshold_i) && !claimed_q;
  assign claim_id_o = irq_o ? 32'd1 : 32'd0;

endmodule
