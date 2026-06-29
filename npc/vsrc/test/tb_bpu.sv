import config_pkg::*;
import build_config_pkg::*;
import global_config_pkg::*;

module tb_bpu (
    // --- 输入端口  ---
    input logic clk_i,
    input logic rst_i,
    input logic ifu_ready_i,
    input logic ifu_valid_i,
    input logic [Cfg.XLEN - 1:0] pc_i,
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
    // --- 输出端口  ---
    output logic [Cfg.XLEN-1:0] npc_o,
    output logic pred_slot_valid_o,
    output logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] pred_slot_idx_o,
    output logic [Cfg.XLEN-1:0] pred_slot_target_o,
    output logic [Cfg.BPU_GHR_BITS-1:0] dbg_ghr_o
);
  // Keep tb_bpu deterministic for legacy hysteresis tests.
  // Frontend integration uses Cfg.BPU_USE_GSHARE.
  localparam bit TB_BPU_USE_GSHARE = 1'b0;
  localparam bit TB_BPU_USE_TAGE = 1'b0;
  localparam bit TB_BPU_USE_ITTAGE = 1'b1;
  localparam int unsigned TB_BPU_BTB_ENTRIES = 128;
  localparam int unsigned TB_BPU_BHT_ENTRIES = 512;
  localparam bit TB_BPU_BTB_HASH_ENABLE = 1'b1;
  localparam bit TB_BPU_BHT_HASH_ENABLE = 1'b1;

  logic ftq_enq_valid;
  logic ftq_enq_ready;
  logic [Cfg.PLEN-1:0] ftq_enq_pc;
  logic ftq_enq_pred_slot_valid;
  logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] ftq_enq_pred_slot_idx;
  logic [Cfg.PLEN-1:0] ftq_enq_pred_target;
  logic [Cfg.PLEN-1:0] ftq_enq_pred_npc;
  assign ftq_enq_ready = ifu_ready_i;
  bpu #(
      .Cfg(Cfg),
      .BTB_ENTRIES(TB_BPU_BTB_ENTRIES),
      .BHT_ENTRIES(TB_BPU_BHT_ENTRIES),
      .BTB_HASH_ENABLE(TB_BPU_BTB_HASH_ENABLE),
      .BHT_HASH_ENABLE(TB_BPU_BHT_HASH_ENABLE),
      .USE_GSHARE(TB_BPU_USE_GSHARE),
      .USE_TAGE(TB_BPU_USE_TAGE),
      .USE_ITTAGE(TB_BPU_USE_ITTAGE)
  ) i_BPU (
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
      .ftq_enq_pc_o(ftq_enq_pc),
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
  assign dbg_ghr_o = i_BPU.ghr_q;
endmodule
