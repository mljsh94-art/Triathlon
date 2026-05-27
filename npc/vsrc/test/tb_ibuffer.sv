// vsrc/test/tb_ibuffer.sv
import config_pkg::*;
import global_config_pkg::*;

module tb_ibuffer #(
    parameter int unsigned TEST_IB_DEPTH = 8
) (
    input logic clk_i,
    input logic rst_ni,

    // --- Frontend Interface (展平) ---
    input  logic                                    fe_valid_i,
    output logic                                    fe_ready_o,
    // [INSTR_PER_FETCH * ILEN - 1 : 0]
    input  logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] fe_instrs_i,
    input  logic [                    Cfg.PLEN-1:0] fe_pc_i,
    input  logic [Cfg.INSTR_PER_FETCH-1:0]          fe_slot_valid_i,
    input  logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] fe_pred_npc_i,
    input  logic [Cfg.INSTR_PER_FETCH*((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] fe_ftq_id_i,
    input  logic [Cfg.INSTR_PER_FETCH*3-1:0] fe_fetch_epoch_i,

    // --- Decode Interface (展平) ---
    output logic                                    ibuf_valid_o,
    input  logic                                    ibuf_ready_i,
    // [DECODE_WIDTH * ILEN - 1 : 0]
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuf_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuf_raw_instrs_o,
    // [DECODE_WIDTH * PLEN - 1 : 0]
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuf_pcs_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuf_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuf_pred_npc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuf_is_rvc_o,
    output logic [Cfg.INSTR_PER_FETCH*((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuf_ftq_id_o,
    output logic [Cfg.INSTR_PER_FETCH*3-1:0] ibuf_fetch_epoch_o,

    // --- Control ---
    input logic flush_i
);
  // 注意：这里假设 DECODE_WIDTH == INSTR_PER_FETCH
  ibuffer #(
      .Cfg(Cfg),
      .IB_DEPTH(TEST_IB_DEPTH),
      .DECODE_WIDTH(Cfg.INSTR_PER_FETCH)
  ) dut (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .fe_valid_i(fe_valid_i),
      .fe_ready_o(fe_ready_o),
      // SystemVerilog 会自动处理 展平向量 到 Packed Array 的赋值
      .fe_instrs_i(fe_instrs_i),
      .fe_pc_i(fe_pc_i),
      .fe_slot_valid_i(fe_slot_valid_i),
      .fe_pred_npc_i(fe_pred_npc_i),
      .fe_ftq_id_i(fe_ftq_id_i),
      .fe_fetch_epoch_i(fe_fetch_epoch_i),

      .ibuf_valid_o(ibuf_valid_o),
      .ibuf_ready_i(ibuf_ready_i),
      .ibuf_instrs_o(ibuf_instrs_o),
      .ibuf_raw_instrs_o(ibuf_raw_instrs_o),
      .ibuf_pcs_o(ibuf_pcs_o),
      .ibuf_slot_valid_o(ibuf_slot_valid_o),
      .ibuf_pred_npc_o(ibuf_pred_npc_o),
      .ibuf_is_rvc_o(ibuf_is_rvc_o),
      .ibuf_ftq_id_o(ibuf_ftq_id_o),
      .ibuf_fetch_epoch_o(ibuf_fetch_epoch_o),

      .flush_i(flush_i)
  );

endmodule
