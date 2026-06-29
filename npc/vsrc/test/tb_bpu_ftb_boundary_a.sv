// FTB 半字 offset — 边界 A（预测命中/miss）专用 BPU 单元 TB。
// 运行（审核通过后）：
//   make -C npc TOPNAME=tb_bpu_ftb_boundary_a SIM_MAIN=csrc/test/test_bpu_ftb_boundary_a.cpp
import config_pkg::*;
import build_config_pkg::*;
import global_config_pkg::*;

module tb_bpu_ftb_boundary_a (
    input logic clk_i,
    input logic rst_i,
    input logic ifu_ready_i,
    input logic ifu_valid_i,
    input logic [Cfg.XLEN-1:0] pc_i,
    input logic update_valid_i,
    input logic [Cfg.XLEN-1:0] update_pc_i,
    input logic update_is_cond_i,
    input logic update_taken_i,
    input logic [Cfg.XLEN-1:0] update_target_i,
    input logic update_is_call_i,
    input logic update_is_ret_i,
    input logic update_is_rvc_i,
    input logic [Cfg.NRET-1:0] ras_update_valid_i,
    input logic [Cfg.NRET-1:0] ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0] ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] ras_update_pc_i,
    input logic flush_i,
    output logic [Cfg.XLEN-1:0] npc_o,
    output logic pred_slot_valid_o,
    output logic [PRED_SLOT_IDX_W-1:0] pred_slot_idx_o,
    output logic [Cfg.XLEN-1:0] pred_slot_target_o,
    output logic [Cfg.PLEN-1:0] ftq_enq_pc_o
);
  localparam bit TB_BPU_USE_GSHARE = 1'b0;
  localparam bit TB_BPU_USE_TAGE = 1'b0;
  localparam bit TB_BPU_USE_ITTAGE = 1'b0;

  logic ftq_enq_valid;
  logic ftq_enq_ready;
  logic ftq_enq_pred_slot_valid;
  logic [PRED_SLOT_IDX_W-1:0] ftq_enq_pred_slot_idx;
  logic [Cfg.PLEN-1:0] ftq_enq_pred_target;
  logic [Cfg.PLEN-1:0] ftq_enq_pred_npc;

  assign ftq_enq_ready = ifu_ready_i;

  bpu #(
      .Cfg(Cfg),
      .BTB_ENTRIES(128),
      .BHT_ENTRIES(512),
      .BTB_HASH_ENABLE(1'b1),
      .BHT_HASH_ENABLE(1'b1),
      .USE_GSHARE(TB_BPU_USE_GSHARE),
      .USE_TAGE(TB_BPU_USE_TAGE),
      .USE_ITTAGE(TB_BPU_USE_ITTAGE)
  ) u_bpu (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .update_valid_i(update_valid_i),
      .update_pc_i(update_pc_i),
      .update_is_cond_i(update_is_cond_i),
      .update_taken_i(update_taken_i),
      .update_target_i(update_target_i),
      .update_is_call_i(update_is_call_i),
      .update_is_ret_i(update_is_ret_i),
      .update_is_rvc_i(update_is_rvc_i),
      .update_ftq_id_i('0),
      .update_fetch_epoch_i('0),
      .update_ghr_i('0),
      .update_ghr_i('0),
      .ras_update_valid_i(ras_update_valid_i),
      .ras_update_is_call_i(ras_update_is_call_i),
      .ras_update_is_ret_i(ras_update_is_ret_i),
      .ras_update_is_rvc_i(ras_update_is_rvc_i),
      .ras_update_pc_i(ras_update_pc_i),
      .flush_i(flush_i),
      .redirect_valid_i(flush_i || ifu_valid_i),
      .redirect_pc_i(pc_i),
      .ftq_enq_valid_o(ftq_enq_valid),
      .ftq_enq_ready_i(ftq_enq_ready),
      .ftq_enq_id_i('0),
      .ftq_enq_epoch_i('0),
      .ftq_enq_pc_o(ftq_enq_pc_o),
      .ftq_enq_pred_slot_valid_o(ftq_enq_pred_slot_valid),
      .ftq_enq_pred_slot_idx_o(ftq_enq_pred_slot_idx),
      .ftq_enq_pred_target_o(ftq_enq_pred_target),
      .ftq_enq_pred_npc_o(ftq_enq_pred_npc),
      .ftq_enq_pred_ghr_o(),
      .ftq_enq_pred_ghr_o()
  );

  assign npc_o = ftq_enq_pred_npc;
  assign pred_slot_valid_o = ftq_enq_pred_slot_valid;
  assign pred_slot_idx_o = ftq_enq_pred_slot_idx;
  assign pred_slot_target_o = ftq_enq_pred_target;
endmodule
