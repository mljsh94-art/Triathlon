import config_pkg::*;
import global_config_pkg::*;

module tb_timer_interrupt #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    input logic clk_i,
    input logic rst_ni,
    input logic timer_irq_i,
    input logic ext_irq_i,

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

    output logic [Cfg.XLEN-1:0] dbg_csr_mtvec_o,
    output logic [Cfg.XLEN-1:0] dbg_csr_mepc_o,
    output logic [Cfg.XLEN-1:0] dbg_csr_mstatus_o,
    output logic [Cfg.XLEN-1:0] dbg_csr_mcause_o,
    output logic                dbg_csr_irq_trap_o,
    output logic [Cfg.PLEN-1:0] dbg_csr_irq_redirect_pc_o,
    output logic                dbg_rob_async_valid_o,
    output logic [Cfg.PLEN-1:0] dbg_rob_async_redirect_pc_o,
    output logic                backend_flush_o,
    output logic [Cfg.PLEN-1:0] backend_redirect_pc_o,
    output logic                dbg_rob_flush_o,
    output logic [Cfg.PLEN-1:0] dbg_rob_flush_pc_o,
    output logic [4:0]          dbg_rob_flush_cause_o,
    output logic                dbg_rob_flush_is_exception_o,
    output logic [Cfg.PLEN-1:0] dbg_rob_flush_src_pc_o
);

  triathlon #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i,
      .rst_ni,
      .timer_irq_i(timer_irq_i),
      .ext_irq_i(ext_irq_i),

      .icache_miss_req_valid_o,
      .icache_miss_req_ready_i,
      .icache_miss_req_paddr_o,
      .icache_miss_req_victim_way_o,
      .icache_miss_req_index_o,

      .icache_refill_valid_i,
      .icache_refill_ready_o,
      .icache_refill_paddr_i,
      .icache_refill_way_i,
      .icache_refill_data_i,

      .dcache_miss_req_valid_o,
      .dcache_miss_req_ready_i,
      .dcache_miss_req_paddr_o,
      .dcache_miss_req_victim_way_o,
      .dcache_miss_req_index_o,

      .dcache_refill_valid_i,
      .dcache_refill_ready_o,
      .dcache_refill_paddr_i,
      .dcache_refill_way_i,
      .dcache_refill_data_i,

      .dcache_wb_req_valid_o,
      .dcache_wb_req_ready_i,
      .dcache_wb_req_paddr_o,
      .dcache_wb_req_data_o
  );

  assign dbg_csr_mtvec_o = dut.u_backend.u_csr.csr_mtvec;
  assign dbg_csr_mepc_o = dut.u_backend.u_csr.csr_mepc;
  assign dbg_csr_mstatus_o = dut.u_backend.u_csr.csr_mstatus;
  assign dbg_csr_mcause_o = dut.u_backend.u_csr.csr_mcause;
  assign dbg_csr_irq_trap_o = dut.u_backend.csr_irq_trap;
  assign dbg_csr_irq_redirect_pc_o = dut.u_backend.csr_irq_trap_redirect_pc;
  assign dbg_rob_async_valid_o = dut.u_backend.u_rob.async_exception_valid_i;
  assign dbg_rob_async_redirect_pc_o = dut.u_backend.u_rob.async_exception_redirect_pc_i;

  assign backend_flush_o = dut.u_backend.backend_flush_o;
  assign backend_redirect_pc_o = dut.u_backend.backend_redirect_pc_o;
  assign dbg_rob_flush_o = dut.u_backend.rob_flush;
  assign dbg_rob_flush_pc_o = dut.u_backend.rob_flush_pc;
  assign dbg_rob_flush_cause_o = dut.u_backend.rob_flush_cause;
  assign dbg_rob_flush_is_exception_o = dut.u_backend.rob_flush_is_exception;
  assign dbg_rob_flush_src_pc_o = dut.u_backend.rob_flush_src_pc;

endmodule
