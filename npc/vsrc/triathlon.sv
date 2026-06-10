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
  // Frontend <-> Backend
  // --------------
  fe_be_bundle_t fe2be;
  be2fe_ctrl_if_t be2fe;

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

  frontend #(
      .Cfg(Cfg)
  ) u_frontend (
      .clk_i,
      .rst_ni,

      .fe2be_o(fe2be),
      .be2fe_i(be2fe),

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

      .fe2be_i(fe2be),
      .fe2be_ready_o(fe2be.ready),
      .be2fe_o(be2fe),
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
