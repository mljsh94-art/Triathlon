module issue_select #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned      RS_DEPTH = Cfg.RS_DEPTH,
    parameter int unsigned      ISSUE_WIDTH = 2,
    parameter int unsigned      RS_IDX_W = $clog2(RS_DEPTH)
) (
    input  wire [RS_DEPTH-1:0] ready_mask,

    output logic [RS_DEPTH-1:0] issue_grant_mask,

    output logic [ISSUE_WIDTH-1:0] issue_valid,
    output logic [RS_IDX_W-1:0]    issue_rs_idx[0:ISSUE_WIDTH-1]
);

  function automatic logic [RS_DEPTH-1:0] find_first_one(input logic [RS_DEPTH-1:0] in_vec);
    logic found;
    begin
      find_first_one = '0;
      found = 1'b0;
      for (int k = 0; k < RS_DEPTH; k++) begin
        if (in_vec[k] && !found) begin
          find_first_one[k] = 1'b1;
          found = 1'b1;
        end
      end
    end
  endfunction

  logic [RS_DEPTH-1:0] mask_stage[0:ISSUE_WIDTH];
  logic [RS_DEPTH-1:0] grant_stage[0:ISSUE_WIDTH-1];

  always_comb begin
    mask_stage[0] = ready_mask;
    issue_grant_mask = '0;
    for (int j = 0; j < ISSUE_WIDTH; j++) begin
      grant_stage[j] = find_first_one(mask_stage[j]);
      mask_stage[j+1] = mask_stage[j] & ~grant_stage[j];
      issue_grant_mask |= grant_stage[j];
    end
  end

  always_comb begin
    for (int j = 0; j < ISSUE_WIDTH; j++) begin
      issue_valid[j] = |grant_stage[j];
      issue_rs_idx[j] = '0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (grant_stage[j][i]) issue_rs_idx[j] = i[RS_IDX_W-1:0];
      end
    end
  end

endmodule
