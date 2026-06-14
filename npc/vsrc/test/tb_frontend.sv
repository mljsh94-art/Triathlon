// vsrc/test/tb_frontend.sv
import config_pkg::*;
import global_config_pkg::*;
import core_contract_pkg::*;

module tb_frontend (
    input logic clk_i,
    input logic rst_ni,

    // decode-ready 出队口
    output logic                                    ibuffer_valid_o,
    input  logic                                    ibuffer_ready_i,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuffer_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] ibuffer_raw_instrs_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuffer_pcs_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuffer_slot_valid_o,
    output logic [Cfg.INSTR_PER_FETCH*Cfg.PLEN-1:0] ibuffer_pred_npc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0]          ibuffer_is_rvc_o,
    output logic [Cfg.INSTR_PER_FETCH*((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] ibuffer_ftq_id_o,
    output logic [Cfg.INSTR_PER_FETCH*3-1:0] ibuffer_fetch_epoch_o,

    input logic                flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,
    input logic                bpu_update_valid_i,
    input logic [Cfg.PLEN-1:0] bpu_update_pc_i,
    input logic                bpu_update_is_cond_i,
    input logic                bpu_update_taken_i,
    input logic [Cfg.PLEN-1:0] bpu_update_target_i,
    input logic                bpu_update_is_call_i,
    input logic                bpu_update_is_ret_i,
    input logic                bpu_update_is_rvc_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_valid_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_call_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_ret_i,
    input logic [Cfg.NRET-1:0] bpu_ras_update_is_rvc_i,
    input logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc_i,

    output logic                                  miss_req_valid_o,
    input  logic                                  miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] miss_req_index_o,

    input  logic                                  refill_valid_i,
    output logic                                  refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] refill_data_i,

    output logic                                  dbg_ifu_req_valid_o,
    output logic                                  dbg_ifu_req_ready_o,
    output logic                                  dbg_ifu_req_fire_o,
    output logic [                  Cfg.PLEN-1:0] dbg_ifu_req_addr_o,
    output logic                                  dbg_ifu_rsp_valid_o,
    output logic                                  dbg_ifu_rsp_capture_o,
    output logic                                  dbg_ifu_ibuf_valid_o,
    output logic [                           3:0] dbg_ifu_outstanding_o,
    output logic [                           3:0] dbg_ifu_pending_o,
    output logic [                           3:0] dbg_ifu_inflight_o,
    output logic                                  dbg_ifu_drop_stale_rsp_o,
    output logic [((Cfg.FTQ_DEPTH >= 2) ? $clog2(Cfg.FTQ_DEPTH) : 1)-1:0] dbg_ibuf_ftq_id_slot0_o,
    output logic [2:0] dbg_ibuf_fetch_epoch_slot0_o,
    output logic dbg_ibuf_meta_uniform_o
);

  fe_be_bundle_t fe2be;
  be2fe_ctrl_if_t be2fe;

  assign fe2be.ready = ibuffer_ready_i;
  assign ibuffer_valid_o = fe2be.valid;
  assign ibuffer_instrs_o = fe2be.instrs;
  assign ibuffer_raw_instrs_o = fe2be.raw_instrs;
  assign ibuffer_pcs_o = fe2be.pcs;
  assign ibuffer_slot_valid_o = fe2be.slot_valid;
  assign ibuffer_pred_npc_o = fe2be.pred_npc;
  assign ibuffer_is_rvc_o = fe2be.is_rvc;
  assign ibuffer_ftq_id_o = fe2be.ftq_id;
  assign ibuffer_fetch_epoch_o = fe2be.fetch_epoch;

  assign be2fe.flush = flush_i;
  assign be2fe.redirect_pc = redirect_pc_i;
  assign be2fe.bpu_update_valid = bpu_update_valid_i;
  assign be2fe.bpu_update_pc = bpu_update_pc_i;
  assign be2fe.bpu_update_is_cond = bpu_update_is_cond_i;
  assign be2fe.bpu_update_taken = bpu_update_taken_i;
  assign be2fe.bpu_update_target = bpu_update_target_i;
  assign be2fe.bpu_update_is_call = bpu_update_is_call_i;
  assign be2fe.bpu_update_is_ret = bpu_update_is_ret_i;
  assign be2fe.bpu_update_is_rvc = bpu_update_is_rvc_i;
  assign be2fe.bpu_ras_update_valid = bpu_ras_update_valid_i;
  assign be2fe.bpu_ras_update_is_call = bpu_ras_update_is_call_i;
  assign be2fe.bpu_ras_update_is_ret = bpu_ras_update_is_ret_i;
  assign be2fe.bpu_ras_update_is_rvc = bpu_ras_update_is_rvc_i;
  assign be2fe.bpu_ras_update_pc = bpu_ras_update_pc_i;
  assign be2fe.mmu_satp = '0;
  assign be2fe.mmu_priv = 2'b11;
  assign be2fe.mmu_sum = 1'b0;
  assign be2fe.mmu_mxr = 1'b0;
  assign be2fe.mmu_sfence_vma = 1'b0;

  frontend #(
      .Cfg(Cfg)
  ) DUT (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .fe2be_o(fe2be),
      .be2fe_i(be2fe),
      .ifetch_fault_valid_o(),
      .ifetch_fault_ready_i(1'b1),
      .ifetch_fault_pc_o(),
      .ifetch_fault_tval_o(),
      .ifetch_fault_cause_o(),
      .pte_req_valid_o(),
      .pte_req_ready_i(1'b1),
      .pte_req_paddr_o(),
      .pte_rsp_valid_i(1'b0),
      .pte_rsp_data_i('0),
      .pte_upd_valid_o(),
      .pte_upd_ready_i(1'b1),
      .pte_upd_paddr_o(),
      .pte_upd_data_o(),

      .miss_req_valid_o     (miss_req_valid_o),
      .miss_req_ready_i     (miss_req_ready_i),
      .miss_req_paddr_o     (miss_req_paddr_o),
      .miss_req_victim_way_o(miss_req_victim_way_o),
      .miss_req_index_o     (miss_req_index_o),

      .refill_valid_i(refill_valid_i),
      .refill_ready_o(refill_ready_o),
      .refill_paddr_i(refill_paddr_i),
      .refill_way_i  (refill_way_i),
      .refill_data_i (refill_data_i)
  );

  assign dbg_ifu_req_valid_o = DUT.ifu2icache_req_handshake.valid;
  assign dbg_ifu_req_ready_o = DUT.icache2ifu_rsp_handshake.ready;
  assign dbg_ifu_req_fire_o = DUT.ifu2icache_req_handshake.valid & DUT.icache2ifu_rsp_handshake.ready;
  assign dbg_ifu_req_addr_o = DUT.ifu2icache_req_addr;
  assign dbg_ifu_rsp_valid_o = DUT.icache2ifu_rsp_handshake.valid;
  assign dbg_ifu_rsp_capture_o = DUT.i_ifu.rsp_capture_w;
  assign dbg_ifu_ibuf_valid_o = DUT.fe2be_o.valid;
  assign dbg_ifu_outstanding_o = 4'(DUT.i_ifu.req_outstanding_w);
  assign dbg_ifu_pending_o = 4'(DUT.i_ifu.req_count_q);
  assign dbg_ifu_inflight_o = 4'(DUT.i_ifu.inf_count_q);
  assign dbg_ifu_drop_stale_rsp_o = DUT.i_ifu.drop_stale_rsp_w;
  assign dbg_ibuf_ftq_id_slot0_o = DUT.fe2be_o.ftq_id[0];
  assign dbg_ibuf_fetch_epoch_slot0_o = DUT.fe2be_o.fetch_epoch[0];
  always_comb begin
    dbg_ibuf_meta_uniform_o = 1'b1;
    for (int i = 1; i < Cfg.INSTR_PER_FETCH; i++) begin
      if (DUT.fe2be_o.slot_valid[i]) begin
        if ((DUT.fe2be_o.ftq_id[i] != DUT.fe2be_o.ftq_id[0]) ||
            (DUT.fe2be_o.fetch_epoch[i] != DUT.fe2be_o.fetch_epoch[0])) begin
          dbg_ibuf_meta_uniform_o = 1'b0;
        end
      end
    end
  end

endmodule
