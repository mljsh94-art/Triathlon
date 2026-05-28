module mem_dep_predictor #(
    parameter int unsigned ROB_IDX_WIDTH = 6,
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned STORE_DEPTH = 8
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic req_fire_i,
    input logic req_is_load_i,
    input logic req_is_store_i,
    input logic [ADDR_WIDTH-1:0] req_addr_i,
    input logic [ROB_IDX_WIDTH-1:0] req_rob_idx_i,

    output logic bypass_allow_o,
    output logic replay_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] replay_rob_idx_o
);

  logic [STORE_DEPTH-1:0] store_valid_q;
  logic [STORE_DEPTH-1:0][ADDR_WIDTH-1:0] store_addr_q;
  logic [STORE_DEPTH-1:0][ROB_IDX_WIDTH-1:0] store_rob_idx_q;

  logic load_conflict_w;

  assign bypass_allow_o = 1'b1;
  assign replay_valid_o = req_fire_i && req_is_load_i && load_conflict_w;
  assign replay_rob_idx_o = req_rob_idx_i;

  always_comb begin
    load_conflict_w = 1'b0;
    for (int i = 0; i < STORE_DEPTH; i++) begin
      if (!load_conflict_w && store_valid_q[i] && (store_addr_q[i] == req_addr_i) &&
          (store_rob_idx_q[i] != req_rob_idx_i)) begin
        load_conflict_w = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      store_valid_q <= '0;
      store_addr_q <= '0;
      store_rob_idx_q <= '0;
    end else if (flush_i) begin
      store_valid_q <= '0;
      store_addr_q <= '0;
      store_rob_idx_q <= '0;
    end else if (req_fire_i && req_is_store_i) begin
      for (int i = STORE_DEPTH - 1; i > 0; i--) begin
        store_valid_q[i] <= store_valid_q[i-1];
        store_addr_q[i] <= store_addr_q[i-1];
        store_rob_idx_q[i] <= store_rob_idx_q[i-1];
      end
      store_valid_q[0] <= 1'b1;
      store_addr_q[0] <= req_addr_i;
      store_rob_idx_q[0] <= req_rob_idx_i;
    end
  end

  initial begin
    assert (STORE_DEPTH > 0)
    else $fatal(1, "mem_dep_predictor STORE_DEPTH must be > 0");
  end

endmodule
