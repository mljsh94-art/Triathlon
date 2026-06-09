import global_config_pkg::*;
import core_contract_pkg::*;

module triathlon #(
    // Config
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    // Subsystem Clock
    input logic clk_i,
    // Asynchronous reset active low
    input logic rst_ni,
    // Platform interrupt inputs
    input logic timer_irq_i,
    input logic ext_irq_i,

    // -----------------------------
    // I-Cache miss/refill interface
    // -----------------------------
    output logic                                  icache_miss_req_valid_o,
    input  logic                                  icache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] icache_miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] icache_miss_req_index_o,

    input  logic                                  icache_refill_valid_i,
    output logic                                  icache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] icache_refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] icache_refill_data_i,

    // -----------------------------
    // D-Cache miss/refill/writeback
    // -----------------------------
    output logic                                  dcache_miss_req_valid_o,
    input  logic                                  dcache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] dcache_miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] dcache_miss_req_index_o,

    input  logic                                  dcache_refill_valid_i,
    output logic                                  dcache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] dcache_refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] dcache_refill_data_i,

    output logic                             dcache_wb_req_valid_o,
    input  logic                             dcache_wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] dcache_wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] dcache_wb_req_data_o,

    // -----------------------------
    // MMIO Uncached Load interface
    // -----------------------------
    output logic                               mmio_req_valid_o,
    input  logic                               mmio_req_ready_i,
    output logic [             Cfg.PLEN-1:0]   mmio_req_addr_o,
    output logic [$bits(decode_pkg::lsu_op_e)-1:0] mmio_req_op_o,

    input  logic                               mmio_rsp_valid_i,
    input  logic [           Cfg.XLEN-1:0]     mmio_rsp_data_i
);

  // --------------
  // Frontend
  // --------------
  logic fe_ibuf_valid;
  logic fe_ibuf_ready;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_ibuf_instrs;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] fe_ibuf_raw_instrs;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] fe_ibuf_pcs;
  logic [Cfg.INSTR_PER_FETCH-1:0] fe_ibuf_slot_valid;
  logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.PLEN-1:0] fe_ibuf_pred_npc;
  logic [Cfg.INSTR_PER_FETCH-1:0] fe_ibuf_is_rvc;
  logic [Cfg.INSTR_PER_FETCH-1:0][((Cfg.IFU_INF_DEPTH >= 2) ? $clog2(Cfg.IFU_INF_DEPTH) : 1)-1:0] fe_ibuf_ftq_id;
  logic [Cfg.INSTR_PER_FETCH-1:0][2:0] fe_ibuf_fetch_epoch;
  fe_be_bundle_t fe_be_bus;

  logic backend_flush;
  logic [Cfg.PLEN-1:0] backend_redirect_pc;
  logic bpu_update_valid;
  logic [Cfg.PLEN-1:0] bpu_update_pc;
  logic bpu_update_is_cond;
  logic bpu_update_taken;
  logic [Cfg.PLEN-1:0] bpu_update_target;
  logic bpu_update_is_call;
  logic bpu_update_is_ret;
  logic bpu_update_is_rvc;
  logic [Cfg.NRET-1:0] bpu_ras_update_valid;
  logic [Cfg.NRET-1:0] bpu_ras_update_is_call;
  logic [Cfg.NRET-1:0] bpu_ras_update_is_ret;
  logic [Cfg.NRET-1:0] bpu_ras_update_is_rvc;
  logic [Cfg.NRET-1:0][Cfg.PLEN-1:0] bpu_ras_update_pc;
  logic [31:0] mmu_satp_state;
  logic [1:0] mmu_priv_mode;
  logic mmu_mstatus_sum;
  logic mmu_mstatus_mxr;
  logic mmu_sfence_vma_flush;
  logic ifetch_fault_valid;
  logic ifetch_fault_ready;
  logic [Cfg.PLEN-1:0] ifetch_fault_pc;
  logic [Cfg.PLEN-1:0] ifetch_fault_tval;
  logic [4:0] ifetch_fault_cause;
  logic ifu_pte_req_valid;
  logic ifu_pte_req_ready;
  logic [31:0] ifu_pte_req_paddr;
  logic ifu_pte_rsp_valid;
  logic [31:0] ifu_pte_rsp_data;
  logic ifu_pte_upd_valid;
  logic ifu_pte_upd_ready;
  logic [31:0] ifu_pte_upd_paddr;
  logic [31:0] ifu_pte_upd_data;

  assign fe_ibuf_ready = fe_be_bus.ready;
  assign fe_be_bus.valid = fe_ibuf_valid;
  assign fe_be_bus.instrs = fe_ibuf_instrs;
  assign fe_be_bus.raw_instrs = fe_ibuf_raw_instrs;
  assign fe_be_bus.pcs = fe_ibuf_pcs;
  assign fe_be_bus.slot_valid = fe_ibuf_slot_valid;
  assign fe_be_bus.pred_npc = fe_ibuf_pred_npc;
  assign fe_be_bus.is_rvc = fe_ibuf_is_rvc;
  assign fe_be_bus.ftq_id = fe_ibuf_ftq_id;
  assign fe_be_bus.fetch_epoch = fe_ibuf_fetch_epoch;

  frontend #(
      .Cfg(Cfg)
  ) u_frontend (
      .clk_i,
      .rst_ni,

      .ibuffer_valid_o(fe_ibuf_valid),
      .ibuffer_ready_i(fe_be_bus.ready),
      .ibuffer_instrs_o(fe_ibuf_instrs),
      .ibuffer_raw_instrs_o(fe_ibuf_raw_instrs),
      .ibuffer_pcs_o(fe_ibuf_pcs),
      .ibuffer_slot_valid_o(fe_ibuf_slot_valid),
      .ibuffer_pred_npc_o(fe_ibuf_pred_npc),
      .ibuffer_is_rvc_o(fe_ibuf_is_rvc),
      .ibuffer_ftq_id_o(fe_ibuf_ftq_id),
      .ibuffer_fetch_epoch_o(fe_ibuf_fetch_epoch),

      .flush_i      (backend_flush),
      .redirect_pc_i(backend_redirect_pc),
      .bpu_update_valid_i(bpu_update_valid),
      .bpu_update_pc_i(bpu_update_pc),
      .bpu_update_is_cond_i(bpu_update_is_cond),
      .bpu_update_taken_i(bpu_update_taken),
      .bpu_update_target_i(bpu_update_target),
      .bpu_update_is_call_i(bpu_update_is_call),
      .bpu_update_is_ret_i(bpu_update_is_ret),
      .bpu_update_is_rvc_i(bpu_update_is_rvc),
      .bpu_ras_update_valid_i(bpu_ras_update_valid),
      .bpu_ras_update_is_call_i(bpu_ras_update_is_call),
      .bpu_ras_update_is_ret_i(bpu_ras_update_is_ret),
      .bpu_ras_update_is_rvc_i(bpu_ras_update_is_rvc),
      .bpu_ras_update_pc_i(bpu_ras_update_pc),
      .mmu_satp_i(mmu_satp_state),
      .mmu_priv_i(mmu_priv_mode),
      .mmu_sum_i(mmu_mstatus_sum),
      .mmu_mxr_i(mmu_mstatus_mxr),
      .mmu_sfence_vma_i(mmu_sfence_vma_flush),
      .ifetch_fault_valid_o(ifetch_fault_valid),
      .ifetch_fault_ready_i(ifetch_fault_ready),
      .ifetch_fault_pc_o(ifetch_fault_pc),
      .ifetch_fault_tval_o(ifetch_fault_tval),
      .ifetch_fault_cause_o(ifetch_fault_cause),
      .pte_req_valid_o(ifu_pte_req_valid),
      .pte_req_ready_i(ifu_pte_req_ready),
      .pte_req_paddr_o(ifu_pte_req_paddr),
      .pte_rsp_valid_i(ifu_pte_rsp_valid),
      .pte_rsp_data_i(ifu_pte_rsp_data),
      .pte_upd_valid_o(ifu_pte_upd_valid),
      .pte_upd_ready_i(ifu_pte_upd_ready),
      .pte_upd_paddr_o(ifu_pte_upd_paddr),
      .pte_upd_data_o(ifu_pte_upd_data),

      .miss_req_valid_o     (icache_miss_req_valid_o),
      .miss_req_ready_i     (icache_miss_req_ready_i),
      .miss_req_paddr_o     (icache_miss_req_paddr_o),
      .miss_req_victim_way_o(icache_miss_req_victim_way_o),
      .miss_req_index_o     (icache_miss_req_index_o),

      .refill_valid_i(icache_refill_valid_i),
      .refill_ready_o(icache_refill_ready_o),
      .refill_paddr_i(icache_refill_paddr_i),
      .refill_way_i  (icache_refill_way_i),
      .refill_data_i (icache_refill_data_i)
  );

  // --------------
  // Backend
  // --------------
  backend #(
      .Cfg(Cfg)
  ) u_backend (
      .clk_i,
      .rst_ni,
      .timer_irq_i(timer_irq_i),
      .ext_irq_i(ext_irq_i),
      .flush_from_backend(1'b0),

      .frontend_ibuf_valid (fe_be_bus.valid),
      .frontend_ibuf_ready (fe_be_bus.ready),
      .frontend_ibuf_instrs(fe_be_bus.instrs),
      .frontend_ibuf_raw_instrs(fe_be_bus.raw_instrs),
      .frontend_ibuf_pcs(fe_be_bus.pcs),
      .frontend_ibuf_slot_valid(fe_be_bus.slot_valid),
      .frontend_ibuf_pred_npc(fe_be_bus.pred_npc),
      .frontend_ibuf_is_rvc(fe_be_bus.is_rvc),
      .frontend_ibuf_ftq_id(fe_be_bus.ftq_id),
      .frontend_ibuf_fetch_epoch(fe_be_bus.fetch_epoch),

      .backend_flush_o      (backend_flush),
      .backend_redirect_pc_o(backend_redirect_pc),
      .bpu_update_valid_o(bpu_update_valid),
      .bpu_update_pc_o(bpu_update_pc),
      .bpu_update_is_cond_o(bpu_update_is_cond),
      .bpu_update_taken_o(bpu_update_taken),
      .bpu_update_target_o(bpu_update_target),
      .bpu_update_is_call_o(bpu_update_is_call),
      .bpu_update_is_ret_o(bpu_update_is_ret),
      .bpu_update_is_rvc_o(bpu_update_is_rvc),
      .bpu_ras_update_valid_o(bpu_ras_update_valid),
      .bpu_ras_update_is_call_o(bpu_ras_update_is_call),
      .bpu_ras_update_is_ret_o(bpu_ras_update_is_ret),
      .bpu_ras_update_is_rvc_o(bpu_ras_update_is_rvc),
      .bpu_ras_update_pc_o(bpu_ras_update_pc),
      .mmu_satp_o(mmu_satp_state),
      .mmu_priv_o(mmu_priv_mode),
      .mmu_sum_o(mmu_mstatus_sum),
      .mmu_mxr_o(mmu_mstatus_mxr),
      .mmu_sfence_vma_o(mmu_sfence_vma_flush),
      .ifu_pte_ld_req_valid_i(ifu_pte_req_valid),
      .ifu_pte_ld_req_ready_o(ifu_pte_req_ready),
      .ifu_pte_ld_req_paddr_i(ifu_pte_req_paddr),
      .ifu_pte_ld_rsp_valid_o(ifu_pte_rsp_valid),
      .ifu_pte_ld_rsp_data_o(ifu_pte_rsp_data),
      .ifu_pte_st_req_valid_i(ifu_pte_upd_valid),
      .ifu_pte_st_req_ready_o(ifu_pte_upd_ready),
      .ifu_pte_st_req_paddr_i(ifu_pte_upd_paddr),
      .ifu_pte_st_req_data_i(ifu_pte_upd_data),
      .ifetch_fault_valid_i(ifetch_fault_valid),
      .ifetch_fault_ready_o(ifetch_fault_ready),
      .ifetch_fault_pc_i(ifetch_fault_pc),
      .ifetch_fault_tval_i(ifetch_fault_tval),
      .ifetch_fault_cause_i(ifetch_fault_cause),

      .dcache_miss_req_valid_o(dcache_miss_req_valid_o),
      .dcache_miss_req_ready_i(dcache_miss_req_ready_i),
      .dcache_miss_req_paddr_o(dcache_miss_req_paddr_o),
      .dcache_miss_req_victim_way_o(dcache_miss_req_victim_way_o),
      .dcache_miss_req_index_o(dcache_miss_req_index_o),

      .dcache_refill_valid_i(dcache_refill_valid_i),
      .dcache_refill_ready_o(dcache_refill_ready_o),
      .dcache_refill_paddr_i(dcache_refill_paddr_i),
      .dcache_refill_way_i  (dcache_refill_way_i),
      .dcache_refill_data_i (dcache_refill_data_i),

      .dcache_wb_req_valid_o(dcache_wb_req_valid_o),
      .dcache_wb_req_ready_i(dcache_wb_req_ready_i),
      .dcache_wb_req_paddr_o(dcache_wb_req_paddr_o),
      .dcache_wb_req_data_o (dcache_wb_req_data_o),

      .mmio_req_valid_o(mmio_req_valid_o),
      .mmio_req_ready_i(mmio_req_ready_i),
      .mmio_req_addr_o (mmio_req_addr_o),
      .mmio_req_op_o   (mmio_req_op_o),
      .mmio_rsp_valid_i(mmio_rsp_valid_i),
      .mmio_rsp_data_i (mmio_rsp_data_i)
  );
endmodule : triathlon
