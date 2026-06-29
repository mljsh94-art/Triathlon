import config_pkg::*;

module retire_redirect_ctrl #(
    parameter config_pkg::cfg_t Cfg = config_pkg::EmptyCfg,
    parameter int unsigned COMMIT_WIDTH = Cfg.NRET,
    parameter int unsigned FTQ_ID_W = ((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1),
    parameter int unsigned FETCH_EPOCH_W = 3,
    parameter int unsigned PRED_GHR_W = (Cfg.BPU_GHR_BITS > 0) ? Cfg.BPU_GHR_BITS : 1,
    parameter int unsigned COMMIT_SEL_W = (COMMIT_WIDTH > 1) ? $clog2(COMMIT_WIDTH) : 1,
    parameter bit ENABLE_COMMIT_RAS_UPDATE = 1'b1
) (
    input logic flush_from_backend_i,
    input logic rob_flush_i,
    input logic [Cfg.PLEN-1:0] rob_flush_pc_i,

    input logic [COMMIT_WIDTH-1:0] commit_valid_i,
    input logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_i,
    input logic [COMMIT_WIDTH-1:0] commit_is_branch_i,
    input logic [COMMIT_WIDTH-1:0] commit_is_jump_i,
    input logic [COMMIT_WIDTH-1:0] commit_is_call_i,
    input logic [COMMIT_WIDTH-1:0] commit_is_ret_i,
    input logic [COMMIT_WIDTH-1:0] commit_is_rvc_i,
    input logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_actual_npc_i,
    input logic [COMMIT_WIDTH-1:0][FTQ_ID_W-1:0] commit_ftq_id_i,
    input logic [COMMIT_WIDTH-1:0][FETCH_EPOCH_W-1:0] commit_fetch_epoch_i,
    input logic [COMMIT_WIDTH-1:0][PRED_GHR_W-1:0] commit_pred_ghr_i,

    output logic backend_flush_o,
    output logic [Cfg.PLEN-1:0] backend_redirect_pc_o,
    output logic [Cfg.PLEN-1:0] retire_redirect_pc_dbg_o,

    output logic bpu_update_valid_o,
    output logic [Cfg.PLEN-1:0] bpu_update_pc_o,
    output logic bpu_update_is_cond_o,
    output logic bpu_update_taken_o,
    output logic [Cfg.PLEN-1:0] bpu_update_target_o,
    output logic bpu_update_is_call_o,
    output logic bpu_update_is_ret_o,
    output logic bpu_update_is_rvc_o,
    output logic [FTQ_ID_W-1:0] bpu_update_ftq_id_dbg_o,
    output logic [FETCH_EPOCH_W-1:0] bpu_update_fetch_epoch_dbg_o,
    output logic [PRED_GHR_W-1:0] bpu_update_ghr_o,
    output logic [COMMIT_SEL_W-1:0] bpu_update_sel_idx_dbg_o,

    output logic [COMMIT_WIDTH-1:0] bpu_ras_update_valid_o,
    output logic [COMMIT_WIDTH-1:0] bpu_ras_update_is_call_o,
    output logic [COMMIT_WIDTH-1:0] bpu_ras_update_is_ret_o,
    output logic [COMMIT_WIDTH-1:0] bpu_ras_update_is_rvc_o,
    output logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc_o
);

  assign backend_flush_o = flush_from_backend_i | rob_flush_i;
  assign backend_redirect_pc_o = rob_flush_pc_i;
  assign retire_redirect_pc_dbg_o = backend_redirect_pc_o;

  always_comb begin
    int sel_idx;
    logic [Cfg.PLEN-1:0] fallthrough_pc;
    logic [Cfg.PLEN-1:0] instr_size;
    bpu_update_valid_o = 1'b0;
    bpu_update_pc_o = '0;
    bpu_update_is_cond_o = 1'b0;
    bpu_update_taken_o = 1'b0;
    bpu_update_target_o = '0;
    bpu_update_is_call_o = 1'b0;
    bpu_update_is_ret_o = 1'b0;
    bpu_update_is_rvc_o = 1'b0;
    bpu_update_ftq_id_dbg_o = '0;
    bpu_update_fetch_epoch_dbg_o = '0;
    bpu_update_ghr_o = '0;
    bpu_update_sel_idx_dbg_o = '0;
    fallthrough_pc = '0;
    instr_size = '0;
    sel_idx = -1;

    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      if (commit_valid_i[i] && commit_is_branch_i[i]) begin
        sel_idx = i;
        break;
      end
    end

    if (sel_idx >= 0) begin
      instr_size = commit_is_rvc_i[sel_idx] ? Cfg.PLEN'(2) : Cfg.PLEN'(4);
      fallthrough_pc = commit_pc_i[sel_idx] + instr_size;
      bpu_update_valid_o = 1'b1;
      bpu_update_pc_o = commit_pc_i[sel_idx];
      bpu_update_is_cond_o = !commit_is_jump_i[sel_idx];
      bpu_update_taken_o = commit_is_jump_i[sel_idx] ? 1'b1 :
                           (commit_actual_npc_i[sel_idx] != fallthrough_pc);
      bpu_update_target_o = commit_actual_npc_i[sel_idx];
      bpu_update_is_call_o = ENABLE_COMMIT_RAS_UPDATE ? commit_is_call_i[sel_idx] : 1'b0;
      bpu_update_is_ret_o = ENABLE_COMMIT_RAS_UPDATE ? commit_is_ret_i[sel_idx] : 1'b0;
      bpu_update_is_rvc_o = commit_is_rvc_i[sel_idx];
      bpu_update_ftq_id_dbg_o = commit_ftq_id_i[sel_idx];
      bpu_update_fetch_epoch_dbg_o = commit_fetch_epoch_i[sel_idx];
      bpu_update_ghr_o = commit_pred_ghr_i[sel_idx];
      bpu_update_sel_idx_dbg_o = COMMIT_SEL_W'(sel_idx);
    end
  end

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      bpu_ras_update_valid_o[i] = ENABLE_COMMIT_RAS_UPDATE &&
                                  commit_valid_i[i] &&
                                  commit_is_branch_i[i] &&
                                  (commit_is_call_i[i] || commit_is_ret_i[i]);
      bpu_ras_update_is_call_o[i] = commit_is_call_i[i];
      bpu_ras_update_is_ret_o[i] = commit_is_ret_i[i];
      bpu_ras_update_is_rvc_o[i] = commit_is_rvc_i[i];
      bpu_ras_update_pc_o[i] = commit_pc_i[i];
    end
  end

endmodule
