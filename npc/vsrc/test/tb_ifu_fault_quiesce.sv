import config_pkg::*;
import global_config_pkg::*;

module tb_ifu_fault_quiesce #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    input logic clk_i,
    input logic rst_i,

    input logic [Cfg.PLEN-1:0] bpu_pred_pc_i,
    input logic flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,
    input logic [31:0] mmu_satp_i,
    input logic [1:0] mmu_priv_i,
    input logic ifetch_fault_ready_i,
    input logic pte_rsp_valid_i,
    input logic [31:0] pte_rsp_data_i,

    output logic bpu_req_valid_o,
    output logic bpu_req_ready_o,
    output logic [Cfg.PLEN-1:0] bpu_query_pc_o,
    output logic icache_req_valid_o,
    output logic [Cfg.PLEN-1:0] icache_req_addr_o,
    output logic pte_req_valid_o,
    output logic [31:0] pte_req_paddr_o,
    output logic ifetch_fault_valid_o,
    output logic [Cfg.PLEN-1:0] ifetch_fault_pc_o
);

  logic ftq_deq_ready;
  logic local_redirect_valid;
  logic [Cfg.PLEN-1:0] local_redirect_pc;
  handshake_t ifu2icache_req_hs;
  handshake_t icache2ifu_rsp_hs;

  assign icache2ifu_rsp_hs.valid = 1'b0;
  assign icache2ifu_rsp_hs.ready = 1'b1;

  assign bpu_req_valid_o = 1'b1;
  assign bpu_req_ready_o = ftq_deq_ready;
  assign bpu_query_pc_o = redirect_pc_i;
  assign icache_req_valid_o = ifu2icache_req_hs.valid;

  ifu #(
      .Cfg(Cfg)
  ) dut (
      .clk(clk_i),
      .rst(rst_i),
      .ftq_deq_valid_i(1'b1),
      .ftq_deq_ready_o(ftq_deq_ready),
      .ftq_deq_pc_i(redirect_pc_i),
      .ftq_deq_pred_slot_valid_i(1'b0),
      .ftq_deq_pred_slot_idx_i('0),
      .ftq_deq_pred_target_i('0),
      .ftq_deq_pred_npc_i(bpu_pred_pc_i),
      .ftq_deq_epoch_i(3'd0),
      .ftq_deq_ftq_id_i('0),
      .ftq_deq_pred_ghr_i('0),
      .ftq_next_pc_i(bpu_pred_pc_i),
      .ifu2icache_req_handshake_o(ifu2icache_req_hs),
      .icache2ifu_rsp_handshake_i(icache2ifu_rsp_hs),
      .ifu2icache_req_addr_o(icache_req_addr_o),
      .icache2ifu_rsp_data_i('0),
      .flush_icache_o(),
      .ifu_ibuffer_rsp_valid_o(),
      .ibuffer_ifu_rsp_ready_i(1'b1),
      .ifu_ibuffer_rsp_pc_o(),
      .ifu_ibuffer_rsp_data_o(),
      .ifu_ibuffer_rsp_slot_valid_o(),
      .ifu_ibuffer_rsp_pred_npc_o(),
      .ifu_ibuffer_rsp_ftq_id_o(),
      .ifu_ibuffer_rsp_pred_ghr_o(),
      .ifu_ibuffer_rsp_fetch_epoch_o(),
      .flush_i(flush_i),
      .redirect_pc_i(redirect_pc_i),
      .local_redirect_valid_o(local_redirect_valid),
      .local_redirect_pc_o(local_redirect_pc),
      .mmu_satp_i(mmu_satp_i),
      .mmu_priv_i(mmu_priv_i),
      .mmu_sum_i(1'b0),
      .mmu_mxr_i(1'b0),
      .mmu_sfence_vma_i(1'b0),
      .pte_req_valid_o(pte_req_valid_o),
      .pte_req_ready_i(1'b1),
      .pte_req_paddr_o(pte_req_paddr_o),
      .pte_rsp_valid_i(pte_rsp_valid_i),
      .pte_rsp_data_i(pte_rsp_data_i),
      .pte_upd_valid_o(),
      .pte_upd_ready_i(1'b1),
      .pte_upd_paddr_o(),
      .pte_upd_data_o(),
      .ifetch_fault_valid_o(ifetch_fault_valid_o),
      .ifetch_fault_ready_i(ifetch_fault_ready_i),
      .ifetch_fault_pc_o(ifetch_fault_pc_o),
      .ifetch_fault_tval_o(),
      .ifetch_fault_cause_o()
  );

  wire _unused_local_redirect = &{1'b0, local_redirect_valid, local_redirect_pc[0]};

endmodule
