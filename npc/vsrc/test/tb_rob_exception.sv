import config_pkg::*;
import decode_pkg::*;

module tb_rob_exception (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic dispatch_valid_i,
    input logic [Cfg.PLEN-1:0] dispatch_pc_i,
    input logic [$bits(decode_pkg::fu_e)-1:0] dispatch_fu_type_i,
    input logic [4:0] dispatch_areg_i,
    input logic dispatch_has_rd_i,
    input logic dispatch_is_branch_i,
    input logic dispatch_is_store_i,
    input logic [1:0] dispatch_st_id_i,

    input logic wb_valid_i,
    input logic [2:0] wb_rob_index_i,
    input logic [Cfg.XLEN-1:0] wb_data_i,
    input logic wb_exception_i,
    input logic [4:0] wb_ecause_i,
    input logic wb_is_mispred_i,
    input logic [Cfg.PLEN-1:0] wb_redirect_pc_i,
    input logic wb_valid2_i,
    input logic [2:0] wb_rob_index2_i,
    input logic [Cfg.XLEN-1:0] wb_data2_i,

    input logic async_exception_valid_i,
    input logic [4:0] async_exception_cause_i,
    input logic [Cfg.PLEN-1:0] async_exception_pc_i,
    input logic [Cfg.PLEN-1:0] async_exception_redirect_pc_i,

    input logic [(QUERY_WIDTH*$clog2(ROB_DEPTH))-1:0] query_rob_idx_i,

    output logic rob_ready_o,
    output logic rob_full_o,
    output logic commit_valid_o,
    output logic commit_we_o,
    output logic [4:0] commit_areg_o,
    output logic [Cfg.XLEN-1:0] commit_wdata_o,
    output logic [2:0] commit_rob_index_o,
    output logic commit_is_store_o,
    output logic [1:0] commit_st_id_o,
    output logic flush_is_mispred_o,
    output logic [QUERY_WIDTH-1:0] query_ready_o,
    output logic [(QUERY_WIDTH*Cfg.XLEN)-1:0] query_data_o,
    output logic sync_exception_valid_o,
    output logic [4:0] sync_exception_cause_o,
    output logic [Cfg.PLEN-1:0] sync_exception_pc_o,
    output logic [Cfg.PLEN-1:0] sync_exception_tval_o,
    output logic flush_o,
    output logic [Cfg.PLEN-1:0] flush_pc_o,
    output logic [4:0] flush_cause_o,
    output logic flush_is_exception_o,
    output logic [Cfg.PLEN-1:0] flush_src_pc_o
);
  localparam int unsigned ROB_DEPTH = 8;
  localparam int unsigned DISPATCH_WIDTH = 1;
  localparam int unsigned COMMIT_WIDTH = 1;
  localparam int unsigned WB_WIDTH = 2;
  localparam int unsigned QUERY_WIDTH = 2;
  localparam int unsigned SB_DEPTH = 4;
  localparam int unsigned ST_IDX_WIDTH = 2;

  logic [DISPATCH_WIDTH-1:0] dispatch_valid_bus;
  logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pc_bus;
  logic [DISPATCH_WIDTH-1:0][Cfg.ILEN-1:0] dispatch_inst_bus;
  logic [DISPATCH_WIDTH-1:0][Cfg.ILEN-1:0] dispatch_decoded_inst_bus;
  decode_pkg::fu_e [DISPATCH_WIDTH-1:0] dispatch_fu_type_bus;
  logic [DISPATCH_WIDTH-1:0][4:0] dispatch_areg_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_has_rd_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_is_branch_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_is_jump_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_is_call_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_is_ret_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_is_rvc_bus;
  logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] dispatch_pred_npc_bus;
  logic [DISPATCH_WIDTH-1:0][decode_pkg::FTQ_ID_W-1:0] dispatch_ftq_id_bus;
  logic [DISPATCH_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] dispatch_fetch_epoch_bus;
  logic [DISPATCH_WIDTH-1:0] dispatch_is_store_bus;
  logic [DISPATCH_WIDTH-1:0][ST_IDX_WIDTH-1:0] dispatch_st_id_bus;

  logic [WB_WIDTH-1:0] wb_valid_bus;
  logic [WB_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] wb_rob_index_bus;
  logic [WB_WIDTH-1:0][Cfg.XLEN-1:0] wb_data_bus;
  logic [WB_WIDTH-1:0] wb_exception_bus;
  logic [WB_WIDTH-1:0][4:0] wb_ecause_bus;
  logic [WB_WIDTH-1:0] wb_is_mispred_bus;
  logic [WB_WIDTH-1:0][Cfg.PLEN-1:0] wb_redirect_pc_bus;

  logic [DISPATCH_WIDTH-1:0] fast_alu_valid_bus;
  logic [DISPATCH_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] fast_alu_rob_idx_bus;
  logic [DISPATCH_WIDTH-1:0][Cfg.XLEN-1:0] fast_alu_data_bus;
  logic [DISPATCH_WIDTH-1:0] fast_alu_is_mispred_bus;
  logic [DISPATCH_WIDTH-1:0][Cfg.PLEN-1:0] fast_alu_redirect_pc_bus;

  logic fast_bru_valid_bus;
  logic [$clog2(ROB_DEPTH)-1:0] fast_bru_rob_idx_bus;
  logic [Cfg.XLEN-1:0] fast_bru_data_bus;
  logic [Cfg.PLEN-1:0] fast_bru_redirect_pc_bus;
  logic fast_bru_can_commit_bus;

  logic [COMMIT_WIDTH-1:0] commit_valid_bus;
  logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pc_bus;
  logic [COMMIT_WIDTH-1:0][Cfg.ILEN-1:0] commit_inst_bus;
  logic [COMMIT_WIDTH-1:0][Cfg.ILEN-1:0] commit_decoded_inst_bus;
  logic [COMMIT_WIDTH-1:0] commit_we_bus;
  logic [COMMIT_WIDTH-1:0][4:0] commit_areg_bus;
  logic [COMMIT_WIDTH-1:0][Cfg.XLEN-1:0] commit_wdata_bus;
  logic [COMMIT_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] commit_rob_index_bus;
  logic [COMMIT_WIDTH-1:0] commit_is_store_bus;
  logic [COMMIT_WIDTH-1:0][ST_IDX_WIDTH-1:0] commit_st_id_bus;
  logic [COMMIT_WIDTH-1:0] commit_is_branch_bus;
  logic [COMMIT_WIDTH-1:0] commit_is_jump_bus;
  logic [COMMIT_WIDTH-1:0] commit_is_call_bus;
  logic [COMMIT_WIDTH-1:0] commit_is_ret_bus;
  logic [COMMIT_WIDTH-1:0] commit_is_rvc_bus;
  logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_pred_npc_bus;
  logic [COMMIT_WIDTH-1:0][Cfg.PLEN-1:0] commit_actual_npc_bus;
  logic [COMMIT_WIDTH-1:0][decode_pkg::FTQ_ID_W-1:0] commit_ftq_id_bus;
  logic [COMMIT_WIDTH-1:0][decode_pkg::FETCH_EPOCH_W-1:0] commit_fetch_epoch_bus;

  logic rob_ready_bus;
  logic flush_bus;
  logic [Cfg.PLEN-1:0] flush_pc_bus;
  logic [4:0] flush_cause_bus;
  logic flush_is_exception_bus;
  logic [Cfg.PLEN-1:0] flush_src_pc_bus;
  logic flush_is_mispred_bus;
  logic flush_is_branch_bus;
  logic flush_is_jump_bus;
  logic sync_exception_valid_bus;
  logic [4:0] sync_exception_cause_bus;
  logic [Cfg.PLEN-1:0] sync_exception_pc_bus;
  logic [Cfg.PLEN-1:0] sync_exception_tval_bus;

  logic [QUERY_WIDTH-1:0][$clog2(ROB_DEPTH)-1:0] query_rob_idx_bus;
  logic [QUERY_WIDTH-1:0] query_ready_bus;
  logic [QUERY_WIDTH-1:0][Cfg.XLEN-1:0] query_data_bus;

  logic rob_empty_bus;
  logic rob_full_bus;
  logic [$clog2(ROB_DEPTH)-1:0] rob_head_bus;
  logic [Cfg.PLEN-1:0] rob_head_pc_bus;

  assign dispatch_valid_bus[0] = dispatch_valid_i;
  assign dispatch_pc_bus[0] = dispatch_pc_i;
  assign dispatch_inst_bus[0] = 32'h00000013;
  assign dispatch_decoded_inst_bus[0] = 32'h00000013;
  assign dispatch_fu_type_bus[0] = decode_pkg::fu_e'(dispatch_fu_type_i);
  assign dispatch_areg_bus[0] = dispatch_areg_i;
  assign dispatch_has_rd_bus[0] = dispatch_has_rd_i;
  assign dispatch_is_branch_bus[0] = dispatch_is_branch_i;
  assign dispatch_is_jump_bus[0] = 1'b0;
  assign dispatch_is_call_bus[0] = 1'b0;
  assign dispatch_is_ret_bus[0] = 1'b0;
  assign dispatch_is_rvc_bus[0] = 1'b0;
  assign dispatch_pred_npc_bus[0] = '0;
  assign dispatch_ftq_id_bus[0] = '0;
  assign dispatch_fetch_epoch_bus[0] = '0;
  assign dispatch_is_store_bus[0] = dispatch_is_store_i;
  assign dispatch_st_id_bus[0] = dispatch_st_id_i;

  assign wb_valid_bus[0] = wb_valid_i;
  assign wb_rob_index_bus[0] = wb_rob_index_i;
  assign wb_data_bus[0] = wb_data_i;
  assign wb_exception_bus[0] = wb_exception_i;
  assign wb_ecause_bus[0] = wb_ecause_i;
  assign wb_is_mispred_bus[0] = wb_is_mispred_i;
  assign wb_redirect_pc_bus[0] = wb_redirect_pc_i;
  assign wb_valid_bus[1] = wb_valid2_i;
  assign wb_rob_index_bus[1] = wb_rob_index2_i;
  assign wb_data_bus[1] = wb_data2_i;
  assign wb_exception_bus[1] = 1'b0;
  assign wb_ecause_bus[1] = '0;
  assign wb_is_mispred_bus[1] = 1'b0;
  assign wb_redirect_pc_bus[1] = '0;

  assign fast_alu_valid_bus = '0;
  assign fast_alu_rob_idx_bus = '0;
  assign fast_alu_data_bus = '0;
  assign fast_alu_is_mispred_bus = '0;
  assign fast_alu_redirect_pc_bus = '0;
  assign fast_bru_valid_bus = 1'b0;
  assign fast_bru_rob_idx_bus = '0;
  assign fast_bru_data_bus = '0;
  assign fast_bru_redirect_pc_bus = '0;
  assign fast_bru_can_commit_bus = 1'b0;
  assign query_rob_idx_bus = query_rob_idx_i;

  assign rob_ready_o = rob_ready_bus;
  assign rob_full_o = rob_full_bus;
  assign commit_valid_o = commit_valid_bus[0];
  assign commit_we_o = commit_we_bus[0];
  assign commit_areg_o = commit_areg_bus[0];
  assign commit_wdata_o = commit_wdata_bus[0];
  assign commit_rob_index_o = commit_rob_index_bus[0];
  assign commit_is_store_o = commit_is_store_bus[0];
  assign commit_st_id_o = commit_st_id_bus[0];
  assign flush_is_mispred_o = flush_is_mispred_bus;
  assign query_ready_o = query_ready_bus;
  assign query_data_o = query_data_bus;
  assign sync_exception_valid_o = sync_exception_valid_bus;
  assign sync_exception_cause_o = sync_exception_cause_bus;
  assign sync_exception_pc_o = sync_exception_pc_bus;
  assign sync_exception_tval_o = sync_exception_tval_bus;

  assign flush_o = flush_bus;
  assign flush_pc_o = flush_pc_bus;
  assign flush_cause_o = flush_cause_bus;
  assign flush_is_exception_o = flush_is_exception_bus;
  assign flush_src_pc_o = flush_src_pc_bus;

  rob #(
      .Cfg(Cfg),
      .ROB_DEPTH(ROB_DEPTH),
      .DISPATCH_WIDTH(DISPATCH_WIDTH),
      .COMMIT_WIDTH(COMMIT_WIDTH),
      .WB_WIDTH(WB_WIDTH),
      .QUERY_WIDTH(QUERY_WIDTH),
      .SB_DEPTH(SB_DEPTH),
      .ST_IDX_WIDTH(ST_IDX_WIDTH)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),

      .dispatch_valid_i(dispatch_valid_bus),
      .dispatch_pc_i(dispatch_pc_bus),
      .dispatch_inst_i(dispatch_inst_bus),
      .dispatch_decoded_inst_i(dispatch_decoded_inst_bus),
      .dispatch_fu_type_i(dispatch_fu_type_bus),
      .dispatch_areg_i(dispatch_areg_bus),
      .dispatch_has_rd_i(dispatch_has_rd_bus),
      .dispatch_is_branch_i(dispatch_is_branch_bus),
      .dispatch_is_jump_i(dispatch_is_jump_bus),
      .dispatch_is_call_i(dispatch_is_call_bus),
      .dispatch_is_ret_i(dispatch_is_ret_bus),
      .dispatch_is_rvc_i(dispatch_is_rvc_bus),
      .dispatch_pred_npc_i(dispatch_pred_npc_bus),
      .dispatch_ftq_id_i(dispatch_ftq_id_bus),
      .dispatch_fetch_epoch_i(dispatch_fetch_epoch_bus),
      .dispatch_is_store_i(dispatch_is_store_bus),
      .dispatch_st_id_i(dispatch_st_id_bus),
      .rob_ready_o(rob_ready_bus),
      .dispatch_rob_index_o(),

      .wb_valid_i(wb_valid_bus),
      .wb_rob_index_i(wb_rob_index_bus),
      .wb_data_i(wb_data_bus),
      .wb_exception_i(wb_exception_bus),
      .wb_ecause_i(wb_ecause_bus),
      .wb_is_mispred_i(wb_is_mispred_bus),
      .wb_redirect_pc_i(wb_redirect_pc_bus),
      .async_exception_valid_i(async_exception_valid_i),
      .async_exception_cause_i(async_exception_cause_i),
      .async_exception_pc_i(async_exception_pc_i),
      .async_exception_redirect_pc_i(async_exception_redirect_pc_i),
      .fast_alu_valid_i(fast_alu_valid_bus),
      .fast_alu_rob_idx_i(fast_alu_rob_idx_bus),
      .fast_alu_data_i(fast_alu_data_bus),
      .fast_alu_is_mispred_i(fast_alu_is_mispred_bus),
      .fast_alu_redirect_pc_i(fast_alu_redirect_pc_bus),
      .fast_bru_valid_i(fast_bru_valid_bus),
      .fast_bru_rob_idx_i(fast_bru_rob_idx_bus),
      .fast_bru_data_i(fast_bru_data_bus),
      .fast_bru_redirect_pc_i(fast_bru_redirect_pc_bus),
      .fast_bru_can_commit_i(fast_bru_can_commit_bus),

      .commit_valid_o(commit_valid_bus),
      .commit_pc_o(commit_pc_bus),
      .commit_inst_o(commit_inst_bus),
      .commit_decoded_inst_o(commit_decoded_inst_bus),
      .commit_we_o(commit_we_bus),
      .commit_areg_o(commit_areg_bus),
      .commit_wdata_o(commit_wdata_bus),
      .commit_rob_index_o(commit_rob_index_bus),
      .commit_is_store_o(commit_is_store_bus),
      .commit_st_id_o(commit_st_id_bus),
      .commit_is_branch_o(commit_is_branch_bus),
      .commit_is_jump_o(commit_is_jump_bus),
      .commit_is_call_o(commit_is_call_bus),
      .commit_is_ret_o(commit_is_ret_bus),
      .commit_is_rvc_o(commit_is_rvc_bus),
      .commit_pred_npc_o(commit_pred_npc_bus),
      .commit_actual_npc_o(commit_actual_npc_bus),
      .commit_ftq_id_o(commit_ftq_id_bus),
      .commit_fetch_epoch_o(commit_fetch_epoch_bus),

      .flush_o(flush_bus),
      .flush_pc_o(flush_pc_bus),
      .flush_cause_o(flush_cause_bus),
      .flush_is_mispred_o(flush_is_mispred_bus),
      .flush_is_exception_o(flush_is_exception_bus),
      .flush_is_branch_o(flush_is_branch_bus),
      .flush_is_jump_o(flush_is_jump_bus),
      .flush_src_pc_o(flush_src_pc_bus),
      .sync_exception_valid_o(sync_exception_valid_bus),
      .sync_exception_cause_o(sync_exception_cause_bus),
      .sync_exception_pc_o(sync_exception_pc_bus),
      .sync_exception_tval_o(sync_exception_tval_bus),

      .query_rob_idx_i(query_rob_idx_bus),
      .query_ready_o(query_ready_bus),
      .query_data_o(query_data_bus),

      .rob_empty_o(rob_empty_bus),
      .rob_full_o(rob_full_bus),
      .rob_head_o(rob_head_bus),
      .rob_head_pc_o(rob_head_pc_bus)
  );

endmodule
