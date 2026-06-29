// FTB 半字 offset — 边界 C（RVC/指令边界）aligner 单元 TB。
// 运行（审核通过后）：
//   make -C npc TOPNAME=tb_instr_aligner_ftb_boundary_c \
//     SIM_MAIN=$PWD/npc/csrc/test/test_instr_aligner_ftb_boundary_c.cpp -B
import config_pkg::*;
import global_config_pkg::*;

module tb_instr_aligner_ftb_boundary_c (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  logic fe_valid_i,
    output logic fe_ready_o,
    input  logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] fe_instrs_i,
    input  logic [Cfg.PLEN-1:0] fe_pc_i,
    input  logic [PRED_SLOT_COUNT-1:0] fe_slot_valid_i,
    input  logic [PRED_SLOT_COUNT*Cfg.PLEN-1:0] fe_pred_npc_i,
    input  logic [PRED_SLOT_COUNT-1:0] fe_pred_taken_i,
    input  logic [Cfg.INSTR_PER_FETCH*((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] fe_ftq_id_i,
    input  logic [Cfg.INSTR_PER_FETCH*3-1:0] fe_fetch_epoch_i,
    input  logic ibuf_aln_ready_i,

    output logic [$clog2(FE_EXPAND_MAX + 1)-1:0] aln_entry_count_o,
    output logic [FE_EXPAND_MAX*Cfg.ILEN-1:0] aln_instrs_o,
    output logic [FE_EXPAND_MAX*Cfg.ILEN-1:0] aln_raw_instrs_o,
    output logic [FE_EXPAND_MAX*Cfg.PLEN-1:0] aln_pcs_o,
    output logic [FE_EXPAND_MAX-1:0] aln_slot_valid_o,
    output logic [FE_EXPAND_MAX*Cfg.PLEN-1:0] aln_pred_npc_o,
    output logic [FE_EXPAND_MAX-1:0] aln_is_rvc_o,
    output logic aln_carry_valid_o,
    output logic [15:0] aln_carry_half_o,
    output logic [Cfg.PLEN-1:0] aln_carry_pc_o
);

  ibuf_entry_t [FE_EXPAND_MAX-1:0] aln_entries;

  instr_aligner #(
      .Cfg(Cfg)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .fe_valid_i(fe_valid_i),
      .fe_ready_o(fe_ready_o),
      .fe_instrs_i(fe_instrs_i),
      .fe_pc_i(fe_pc_i),
      .fe_slot_valid_i(fe_slot_valid_i),
      .fe_pred_npc_i(fe_pred_npc_i),
      .fe_pred_taken_i(fe_pred_taken_i),
      .fe_ftq_id_i(fe_ftq_id_i),
      .fe_pred_ghr_i('0),
      .fe_fetch_epoch_i(fe_fetch_epoch_i),
      .ibuf_aln_ready_i(ibuf_aln_ready_i),
      .aln_entry_count_o(aln_entry_count_o),
      .aln_entries_o(aln_entries)
  );

  assign aln_carry_valid_o = dut.carry_valid_q;
  assign aln_carry_half_o = dut.carry_half_q;
  assign aln_carry_pc_o = dut.carry_pc_q;

  always_comb begin
    for (int i = 0; i < FE_EXPAND_MAX; i++) begin
      aln_instrs_o[(i+1)*Cfg.ILEN-1 -: Cfg.ILEN] = aln_entries[i].instr;
      aln_raw_instrs_o[(i+1)*Cfg.ILEN-1 -: Cfg.ILEN] = aln_entries[i].raw_inst;
      aln_pcs_o[(i+1)*Cfg.PLEN-1 -: Cfg.PLEN] = aln_entries[i].pc;
      aln_slot_valid_o[i] = aln_entries[i].slot_valid;
      aln_pred_npc_o[(i+1)*Cfg.PLEN-1 -: Cfg.PLEN] = aln_entries[i].pred_npc;
      aln_is_rvc_o[i] = aln_entries[i].is_rvc;
    end
  end

endmodule
