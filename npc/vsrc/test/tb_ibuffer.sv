// vsrc/test/tb_ibuffer.sv
import config_pkg::*;
import global_config_pkg::*;

module tb_ibuffer #(
    parameter int unsigned TEST_IB_DEPTH = 8
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic                                    aln_valid_i,
    output logic                                    aln_ready_o,
    input  logic [FE_EXPAND_MAX*Cfg.ILEN-1:0]        aln_instrs_i,
    input  logic [FE_EXPAND_MAX*Cfg.ILEN-1:0]        aln_raw_instrs_i,
    input  logic [FE_EXPAND_MAX*Cfg.PLEN-1:0]        aln_pcs_i,
    input  logic [FE_EXPAND_MAX-1:0]                 aln_slot_valid_i,
    input  logic [FE_EXPAND_MAX*Cfg.PLEN-1:0]        aln_pred_npc_i,
    input  logic [FE_EXPAND_MAX-1:0]                 aln_is_rvc_i,
    input  logic [FE_EXPAND_MAX*((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] aln_ftq_id_i,
    input  logic [FE_EXPAND_MAX*3-1:0]               aln_fetch_epoch_i,
    input  logic [$clog2(FE_EXPAND_MAX + 1)-1:0]    aln_entry_count_i,

    output logic                                    ibuf_valid_o,
    input  logic                                    ibuf_ready_i,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuf_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuf_raw_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuf_pcs_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuf_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuf_pred_npc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuf_is_rvc_o,
    output logic [Cfg.INSTR_PER_FETCH*((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ibuf_ftq_id_o,
    output logic [Cfg.INSTR_PER_FETCH*3-1:0] ibuf_fetch_epoch_o,

    input logic flush_i
);

  ibuf_entry_t [FE_EXPAND_MAX-1:0] aln_entries;

  always_comb begin
    for (int i = 0; i < FE_EXPAND_MAX; i++) begin
      aln_entries[i].instr = aln_instrs_i[(i+1)*Cfg.ILEN-1 -: Cfg.ILEN];
      aln_entries[i].raw_inst = aln_raw_instrs_i[(i+1)*Cfg.ILEN-1 -: Cfg.ILEN];
      aln_entries[i].pc = aln_pcs_i[(i+1)*Cfg.PLEN-1 -: Cfg.PLEN];
      aln_entries[i].slot_valid = aln_slot_valid_i[i];
      aln_entries[i].pred_npc = aln_pred_npc_i[(i+1)*Cfg.PLEN-1 -: Cfg.PLEN];
      aln_entries[i].is_rvc = aln_is_rvc_i[i];
      aln_entries[i].ftq_id = aln_ftq_id_i[(i+1)*((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1 -: ((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)];
      aln_entries[i].fetch_epoch = aln_fetch_epoch_i[(i+1)*3-1 -: 3];
    end
  end

  ibuffer #(
      .Cfg(Cfg),
      .IB_DEPTH(TEST_IB_DEPTH),
      .DECODE_WIDTH(Cfg.INSTR_PER_FETCH)
  ) dut (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .aln_valid_i(aln_valid_i),
      .aln_ready_o(aln_ready_o),
      .aln_entries_i(aln_entries),
      .aln_entry_count_i(aln_entry_count_i),

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
