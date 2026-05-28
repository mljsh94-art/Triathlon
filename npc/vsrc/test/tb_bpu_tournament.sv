import config_pkg::*;
import build_config_pkg::*;
import global_config_pkg::*;

module tb_bpu_tournament (
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
    output logic [Cfg.XLEN-1:0] npc_o,
    output logic pred_slot_valid_o,
    output logic [$clog2(Cfg.INSTR_PER_FETCH)-1:0] pred_slot_idx_o,
    output logic [Cfg.XLEN-1:0] pred_slot_target_o
);
  localparam int unsigned TB_BPU_BTB_ENTRIES = 16;
  localparam int unsigned TB_BPU_BHT_ENTRIES = 8;

  handshake_t ifu_to_bpu_handshake_i;
  handshake_t bpu_to_ifu_handshake_o;
  ifu_to_bpu_t ifu_to_bpu_i;
  bpu_to_ifu_t bpu_to_ifu_o;

  assign ifu_to_bpu_i.pc = pc_i;
  assign ifu_to_bpu_handshake_i.ready = ifu_ready_i;
  assign ifu_to_bpu_handshake_i.valid = ifu_valid_i;

  bpu #(
      .Cfg(Cfg),
      .BTB_ENTRIES(TB_BPU_BTB_ENTRIES),
      .BHT_ENTRIES(TB_BPU_BHT_ENTRIES),
      .BTB_HASH_ENABLE(1'b0),
      .BHT_HASH_ENABLE(1'b0),
      .USE_GSHARE(1'b1),
      .USE_TAGE(1'b0),
      .GHR_BITS(1)
  ) i_BPU (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .ifu_to_bpu_handshake_i(ifu_to_bpu_handshake_i),
      .ifu_to_bpu_i(ifu_to_bpu_i),
      .update_valid_i(update_valid_i),
      .update_pc_i(update_pc_i),
      .update_is_cond_i(update_is_cond_i),
      .update_taken_i(update_taken_i),
      .update_target_i(update_target_i),
      .update_is_call_i(update_is_call_i),
      .update_is_ret_i(update_is_ret_i),
      .update_is_rvc_i(update_is_rvc_i),
      .ras_update_valid_i(ras_update_valid_i),
      .ras_update_is_call_i(ras_update_is_call_i),
      .ras_update_is_ret_i(ras_update_is_ret_i),
      .ras_update_is_rvc_i(ras_update_is_rvc_i),
      .ras_update_pc_i(ras_update_pc_i),
      .flush_i(flush_i),
      .bpu_to_ifu_handshake_o(bpu_to_ifu_handshake_o),
      .bpu_to_ifu_o(bpu_to_ifu_o)
  );

  assign npc_o = bpu_to_ifu_o.npc;
  assign pred_slot_valid_o = bpu_to_ifu_o.pred_slot_valid;
  assign pred_slot_idx_o = bpu_to_ifu_o.pred_slot_idx;
  assign pred_slot_target_o = bpu_to_ifu_o.pred_slot_target;
endmodule
