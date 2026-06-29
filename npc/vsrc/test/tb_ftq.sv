import config_pkg::*;
import global_config_pkg::*;

module tb_ftq #(
    parameter int unsigned TB_FTQ_DEPTH = 4
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,

    input  logic        enq_valid_i,
    output logic        enq_ready_o,
    input  logic [Cfg.PLEN-1:0] enq_pc_i,
    input  logic        enq_pred_slot_valid_i,
    input  logic [((Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1)-1:0] enq_pred_slot_idx_i,
    input  logic [Cfg.PLEN-1:0] enq_pred_target_i,
    input  logic [Cfg.PLEN-1:0] enq_pred_npc_i,
    input  logic [PRED_GHR_W-1:0] enq_pred_ghr_i,
    input  logic [2:0]  enq_epoch_i,

    output logic        deq_valid_o,
    input  logic        deq_ready_i,
    output logic [Cfg.PLEN-1:0] deq_pc_o,
    output logic        deq_pred_slot_valid_o,
    output logic [((Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1)-1:0] deq_pred_slot_idx_o,
    output logic [Cfg.PLEN-1:0] deq_pred_target_o,
    output logic [Cfg.PLEN-1:0] deq_pred_npc_o,
    output logic [PRED_GHR_W-1:0] deq_pred_ghr_o,
    output logic [2:0]  deq_epoch_o,
    output logic [((TB_FTQ_DEPTH > 1) ? $clog2(TB_FTQ_DEPTH) : 1)-1:0] deq_ftq_id_o,

    output logic [((TB_FTQ_DEPTH > 1) ? $clog2(TB_FTQ_DEPTH + 1) : 1)-1:0] dbg_count_o,
    output logic        dbg_full_o,
    output logic        dbg_empty_o
);

  localparam int unsigned EPOCH_W = 3;
  localparam int unsigned CNT_W = (TB_FTQ_DEPTH > 1) ? $clog2(TB_FTQ_DEPTH + 1) : 1;

  logic [CNT_W-1:0] count_w;

  ftq #(
      .Cfg(Cfg),
      .DEPTH(TB_FTQ_DEPTH),
      .EPOCH_W(EPOCH_W)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .enq_valid_i(enq_valid_i),
      .enq_ready_o(enq_ready_o),
      .enq_pc_i(enq_pc_i),
      .enq_pred_slot_valid_i(enq_pred_slot_valid_i),
      .enq_pred_slot_idx_i(enq_pred_slot_idx_i),
      .enq_pred_target_i(enq_pred_target_i),
      .enq_pred_npc_i(enq_pred_npc_i),
      .enq_pred_ghr_i(enq_pred_ghr_i),
      .enq_epoch_i(enq_epoch_i),
      .deq_valid_o(deq_valid_o),
      .deq_ready_i(deq_ready_i),
      .deq_pc_o(deq_pc_o),
      .deq_pred_slot_valid_o(deq_pred_slot_valid_o),
      .deq_pred_slot_idx_o(deq_pred_slot_idx_o),
      .deq_pred_target_o(deq_pred_target_o),
      .deq_pred_npc_o(deq_pred_npc_o),
      .deq_pred_ghr_o(deq_pred_ghr_o),
      .deq_epoch_o(deq_epoch_o),
      .deq_ftq_id_o(deq_ftq_id_o),
      .count_o(count_w)
  );

  assign dbg_count_o = count_w;
  assign dbg_full_o = (count_w == CNT_W'(TB_FTQ_DEPTH));
  assign dbg_empty_o = (count_w == '0);

endmodule
