// tb_ftq.sv — Verilator-compatible wrapper for FTQ FIFO testing
// Exposes all FTQ ports as top-level I/O for the C++ driver.

import config_pkg::*;

module tb_ftq (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,

    // === BPU 写入端 (Enqueue) ===
    input  logic        enq_valid_i,
    output logic        enq_ready_o,
    input  logic [31:0] enq_pc_i,
    input  logic        enq_pred_slot_valid_i,
    input  logic [0:0]  enq_pred_slot_idx_i,
    input  logic [31:0] enq_pred_target_i,
    input  logic [31:0] enq_pred_npc_i,
    input  logic [2:0]  enq_epoch_i,

    // === IFU 读取端 (Dequeue) ===
    output logic        deq_valid_o,
    input  logic        deq_ready_i,
    output logic [31:0] deq_pc_o,
    output logic        deq_pred_slot_valid_o,
    output logic [0:0]  deq_pred_slot_idx_o,
    output logic [31:0] deq_pred_target_o,
    output logic [31:0] deq_pred_npc_o,
    output logic [2:0]  deq_epoch_o,
    output logic [1:0]  deq_ftq_id_o,

    // === 状态 ===
    output logic [2:0]  count_o
);

  localparam int unsigned DEPTH = 4;
  localparam int unsigned EPOCH_W = 3;

  // Build a minimal Cfg
  localparam config_pkg::cfg_t TestCfg = '{
    PLEN: 32,
    INSTR_PER_FETCH: 2,
    XLEN: 32,
    VLEN: 32,
    ILEN: 32,
    RESET_VECTOR: 32'h80000000,
    NRET: 1,
    GPLEN: 32,
    FETCH_WIDTH: 8,
    default: 0
  };

  ftq #(
      .Cfg(TestCfg),
      .DEPTH(DEPTH),
      .EPOCH_W(EPOCH_W)
  ) u_ftq (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .enq_valid_i        (enq_valid_i),
      .enq_ready_o        (enq_ready_o),
      .enq_pc_i           (enq_pc_i),
      .enq_pred_slot_valid_i(enq_pred_slot_valid_i),
      .enq_pred_slot_idx_i(enq_pred_slot_idx_i),
      .enq_pred_target_i  (enq_pred_target_i),
      .enq_pred_npc_i     (enq_pred_npc_i),
      .enq_epoch_i        (enq_epoch_i),
      .deq_valid_o        (deq_valid_o),
      .deq_ready_i        (deq_ready_i),
      .deq_pc_o           (deq_pc_o),
      .deq_pred_slot_valid_o(deq_pred_slot_valid_o),
      .deq_pred_slot_idx_o(deq_pred_slot_idx_o),
      .deq_pred_target_o  (deq_pred_target_o),
      .deq_pred_npc_o     (deq_pred_npc_o),
      .deq_epoch_o        (deq_epoch_o),
      .deq_ftq_id_o       (deq_ftq_id_o),
      .count_o            (count_o)
  );

endmodule
