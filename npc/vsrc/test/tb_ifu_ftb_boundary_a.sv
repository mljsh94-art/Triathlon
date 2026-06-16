// FTB 半字 offset — 边界 A3（IFU 半字 slot_valid/pred_taken 展开）专用 TB。
// 运行（审核通过后）：
//   make -C npc TOPNAME=tb_ifu_ftb_boundary_a SIM_MAIN=csrc/test/test_ifu_ftb_boundary_a.cpp
import config_pkg::*;
import global_config_pkg::*;

module tb_ifu_ftb_boundary_a #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    input logic clk_i,
    input logic rst_i,
    input logic flush_i,
    input logic [Cfg.PLEN-1:0] redirect_pc_i,

    input logic ftq_deq_valid_i,
    input logic [Cfg.PLEN-1:0] ftq_deq_pc_i,
    input logic ftq_deq_pred_slot_valid_i,
    input logic [PRED_SLOT_IDX_W-1:0] ftq_deq_pred_slot_idx_i,
    input logic [Cfg.PLEN-1:0] ftq_deq_pred_target_i,
    input logic [Cfg.PLEN-1:0] ftq_deq_pred_npc_i,

    input logic icache_rsp_valid_i,
    input logic [Cfg.INSTR_PER_FETCH*Cfg.ILEN-1:0] icache_rsp_data_i,
    input logic ibuf_ready_i,

    output logic ftq_deq_ready_o,
    output logic icache_req_valid_o,
    output logic [Cfg.PLEN-1:0] icache_req_addr_o,

    output logic ibuf_valid_o,
    output logic [Cfg.PLEN-1:0] ibuf_pc_o,
    output logic [PRED_SLOT_COUNT-1:0] ibuf_slot_valid_o,
    output logic [PRED_SLOT_COUNT*Cfg.PLEN-1:0] ibuf_pred_npc_o,
    output logic [PRED_SLOT_COUNT-1:0] ibuf_pred_taken_o
);
  localparam int unsigned FTQ_ID_W = global_config_pkg::FTQ_ID_W;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] icache_rsp_data;
  handshake_t ifu2icache_req;
  handshake_t icache2ifu_rsp;
  logic [Cfg.VLEN-1:0] ifu_req_addr;

  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] ibuf_data;
  logic [Cfg.INSTR_PER_FETCH-1:0][FTQ_ID_W-1:0] ibuf_ftq_id;
  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] ibuf_fetch_epoch;
  logic flush_icache;
  logic local_redirect_valid;
  logic [Cfg.PLEN-1:0] local_redirect_pc;

  assign icache_rsp_data = icache_rsp_data_i;
  assign icache2ifu_rsp.valid = icache_rsp_valid_i;
  assign icache2ifu_rsp.ready = 1'b1;
  assign icache_req_valid_o = ifu2icache_req.valid;
  assign icache_req_addr_o = ifu_req_addr[Cfg.PLEN-1:0];

  ifu #(
      .Cfg(Cfg)
  ) dut (
      .clk(clk_i),
      .rst(rst_i),
      .ftq_deq_valid_i(ftq_deq_valid_i),
      .ftq_deq_ready_o(ftq_deq_ready_o),
      .ftq_deq_pc_i(ftq_deq_pc_i),
      .ftq_deq_pred_slot_valid_i(ftq_deq_pred_slot_valid_i),
      .ftq_deq_pred_slot_idx_i(ftq_deq_pred_slot_idx_i),
      .ftq_deq_pred_target_i(ftq_deq_pred_target_i),
      .ftq_deq_pred_npc_i(ftq_deq_pred_npc_i),
      .ftq_deq_epoch_i(3'd0),
      .ftq_deq_ftq_id_i('0),
      .ftq_next_pc_i(ftq_deq_pred_npc_i),
      .ifu2icache_req_handshake_o(ifu2icache_req),
      .icache2ifu_rsp_handshake_i(icache2ifu_rsp),
      .ifu2icache_req_addr_o(ifu_req_addr),
      .icache2ifu_rsp_data_i(icache_rsp_data),
      .flush_icache_o(flush_icache),
      .ifu_ibuffer_rsp_valid_o(ibuf_valid_o),
      .ifu_ibuffer_rsp_pc_o(ibuf_pc_o),
      .ibuffer_ifu_rsp_ready_i(ibuf_ready_i),
      .ifu_ibuffer_rsp_data_o(ibuf_data),
      .ifu_ibuffer_rsp_slot_valid_o(ibuf_slot_valid_o),
      .ifu_ibuffer_rsp_pred_npc_o(ibuf_pred_npc_o),
      .ifu_ibuffer_rsp_pred_taken_o(ibuf_pred_taken_o),
      .ifu_ibuffer_rsp_ftq_id_o(ibuf_ftq_id),
      .ifu_ibuffer_rsp_fetch_epoch_o(ibuf_fetch_epoch),
      .flush_i(flush_i),
      .redirect_pc_i(redirect_pc_i),
      .local_redirect_valid_o(local_redirect_valid),
      .local_redirect_pc_o(local_redirect_pc),
      .mmu_satp_i(32'd0),
      .mmu_priv_i(2'b11),
      .mmu_sum_i(1'b0),
      .mmu_mxr_i(1'b0),
      .mmu_sfence_vma_i(1'b0),
      .pte_req_valid_o(),
      .pte_req_ready_i(1'b1),
      .pte_req_paddr_o(),
      .pte_rsp_valid_i(1'b0),
      .pte_rsp_data_i(32'd0),
      .pte_upd_valid_o(),
      .pte_upd_ready_i(1'b1),
      .pte_upd_paddr_o(),
      .pte_upd_data_o(),
      .ifetch_fault_valid_o(),
      .ifetch_fault_ready_i(1'b1),
      .ifetch_fault_pc_o(),
      .ifetch_fault_tval_o(),
      .ifetch_fault_cause_o()
  );

  wire _unused = &{
      1'b0,
      flush_icache,
      ibuf_data[0][0],
      ibuf_ftq_id[0][0],
      ibuf_fetch_epoch[0][0],
      local_redirect_valid,
      local_redirect_pc[0]
  };
endmodule
