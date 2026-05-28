import config_pkg::*;
import global_config_pkg::*;

module tb_ifu_mmu #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    input logic clk_i,
    input logic rst_i,
    input logic flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,

    input logic bpu_valid_i,
    input logic [Cfg.PLEN-1:0] bpu_predicted_pc_i,
    input logic bpu_pred_slot_valid_i,
    input logic [((Cfg.INSTR_PER_FETCH > 1) ? $clog2(Cfg.INSTR_PER_FETCH) : 1)-1:0] bpu_pred_slot_idx_i,
    input logic [Cfg.PLEN-1:0] bpu_pred_target_i,

    input logic icache_req_ready_i,
    input logic icache_rsp_valid_i,
    input logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] icache_rsp_data_i,

    input logic [31:0] mmu_satp_i,
    input logic [1:0]  mmu_priv_i,
    input logic        mmu_sum_i,
    input logic        mmu_mxr_i,
    input logic        mmu_sfence_vma_i,

    input logic pte_req_ready_i,
    output logic pte_req_valid_o,
    output logic [31:0] pte_req_paddr_o,
    input logic pte_rsp_valid_i,
    input logic [31:0] pte_rsp_data_i,
    input logic pte_upd_ready_i,
    output logic pte_upd_valid_o,
    output logic [31:0] pte_upd_paddr_o,
    output logic [31:0] pte_upd_data_o,

    input logic ifetch_fault_ready_i,
    output logic ifetch_fault_valid_o,
    output logic [Cfg.PLEN-1:0] ifetch_fault_pc_o,
    output logic [Cfg.PLEN-1:0] ifetch_fault_tval_o,
    output logic [4:0] ifetch_fault_cause_o,

    output logic bpu_fire_o,
    output logic [Cfg.PLEN-1:0] ifu_query_pc_o,
    output logic icache_req_valid_o,
    output logic [Cfg.PLEN-1:0] icache_req_addr_o
);

  handshake_t ifu2bpu_handshake;
  handshake_t bpu2ifu_handshake;
  logic [Cfg.PLEN-1:0] ifu2bpu_pc;

  handshake_t ifu2icache_req_handshake;
  handshake_t icache2ifu_rsp_handshake;
  logic [Cfg.VLEN-1:0] ifu2icache_req_addr;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache_rsp_data;

  logic ifu_ibuf_valid;
  logic [Cfg.PLEN-1:0] ifu_ibuf_pc;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ifu_ibuf_data;
  logic [Cfg.INSTR_PER_FETCH-1:0] ifu_ibuf_slot_valid;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] ifu_ibuf_pred_npc;
  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] ifu_ibuf_ftq_id;
  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] ifu_ibuf_fetch_epoch;
  logic flush_icache;

  assign bpu2ifu_handshake.valid = bpu_valid_i;
  assign bpu2ifu_handshake.ready = 1'b1;
  assign icache2ifu_rsp_handshake.ready = icache_req_ready_i;
  assign icache2ifu_rsp_handshake.valid = icache_rsp_valid_i;
  assign icache_rsp_data = icache_rsp_data_i;

  assign bpu_fire_o = ifu2bpu_handshake.ready;
  assign ifu_query_pc_o = ifu2bpu_pc;
  assign icache_req_valid_o = ifu2icache_req_handshake.valid;
  assign icache_req_addr_o = ifu2icache_req_addr[Cfg.PLEN-1:0];

  ifu #(
      .Cfg(Cfg)
  ) dut (
      .clk(clk_i),
      .rst(rst_i),
      .ifu2bpu_handshake_o(ifu2bpu_handshake),
      .bpu2ifu_handshake_i(bpu2ifu_handshake),
      .ifu2bpu_pc_o(ifu2bpu_pc),
      .bpu2ifu_predicted_pc_i(bpu_predicted_pc_i),
      .bpu2ifu_pred_slot_valid_i(bpu_pred_slot_valid_i),
      .bpu2ifu_pred_slot_idx_i(bpu_pred_slot_idx_i),
      .bpu2ifu_pred_target_i(bpu_pred_target_i),
      .ifu2icache_req_handshake_o(ifu2icache_req_handshake),
      .icache2ifu_rsp_handshake_i(icache2ifu_rsp_handshake),
      .ifu2icache_req_addr_o(ifu2icache_req_addr),
      .icache2ifu_rsp_data_i(icache_rsp_data),
      .flush_icache_o(flush_icache),
      .ifu_ibuffer_rsp_valid_o(ifu_ibuf_valid),
      .ifu_ibuffer_rsp_pc_o(ifu_ibuf_pc),
      .ibuffer_ifu_rsp_ready_i(1'b1),
      .ifu_ibuffer_rsp_data_o(ifu_ibuf_data),
      .ifu_ibuffer_rsp_slot_valid_o(ifu_ibuf_slot_valid),
      .ifu_ibuffer_rsp_pred_npc_o(ifu_ibuf_pred_npc),
      .ifu_ibuffer_rsp_ftq_id_o(ifu_ibuf_ftq_id),
      .ifu_ibuffer_rsp_fetch_epoch_o(ifu_ibuf_fetch_epoch),
      .flush_i(flush_i),
      .redirect_pc_i(redirect_pc_i),
      .mmu_satp_i(mmu_satp_i),
      .mmu_priv_i(mmu_priv_i),
      .mmu_sum_i(mmu_sum_i),
      .mmu_mxr_i(mmu_mxr_i),
      .mmu_sfence_vma_i(mmu_sfence_vma_i),
      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(pte_req_ready_i),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(pte_upd_valid_o),
      .pte_upd_ready_i(pte_upd_ready_i),
      .pte_upd_paddr_o(pte_upd_paddr_o),
      .pte_upd_data_o(pte_upd_data_o),
      .ifetch_fault_valid_o(ifetch_fault_valid_o),
      .ifetch_fault_ready_i(ifetch_fault_ready_i),
      .ifetch_fault_pc_o(ifetch_fault_pc_o),
      .ifetch_fault_tval_o(ifetch_fault_tval_o),
      .ifetch_fault_cause_o(ifetch_fault_cause_o)
  );

  wire _unused = &{
      1'b0,
      flush_icache,
      ifu_ibuf_valid,
      ifu_ibuf_pc[0],
      ifu_ibuf_data[0][0],
      ifu_ibuf_slot_valid[0],
      ifu_ibuf_pred_npc[0][0],
      ifu_ibuf_ftq_id[0][0],
      ifu_ibuf_fetch_epoch[0][0]
  };

endmodule
