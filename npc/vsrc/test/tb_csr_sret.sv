import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_csr_sret #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg
) (
    input logic clk_i,
    input logic rst_ni,

    input logic        csr_valid_i,
    input logic [2:0]  op_i,  // 0:nop 1:csrw 2:mret 3:sret
    input logic [11:0] csr_addr_i,
    input logic [Cfg.XLEN-1:0] rs1_data_i,
    input logic [Cfg.PLEN-1:0] pc_i,

    input logic async_exception_inject_i,
    input logic [4:0] async_exception_cause_i,
    input logic [Cfg.PLEN-1:0] async_exception_tval_i,
    input logic [Cfg.PLEN-1:0] trap_pc_i,

    output logic csr_valid_o,
    output logic csr_exception_o,
    output logic csr_is_mispred_o,
    output logic [Cfg.PLEN-1:0] csr_redirect_pc_o,
    output logic [1:0] priv_mode_o,
    output logic [Cfg.XLEN-1:0] dbg_mstatus_o,
    output logic [Cfg.XLEN-1:0] dbg_medeleg_o,
    output logic [Cfg.XLEN-1:0] dbg_sepc_o,
    output logic [Cfg.XLEN-1:0] dbg_scause_o,
    output logic [Cfg.XLEN-1:0] dbg_stval_o
);

  decode_pkg::uop_t uop;

  always_comb begin
    uop = '0;
    uop.valid = csr_valid_i;
    uop.fu = FU_CSR;
    uop.pc = pc_i;
    uop.inst = '0;
    uop.raw_inst = '0;
    uop.csr_op = CSR_RW;
    uop.csr_addr = csr_addr_i;
    uop.is_csr = (op_i == 3'd1);
    uop.is_mret = (op_i == 3'd2);
    uop.is_sret = (op_i == 3'd3);
  end

  execute_csr #(
      .Cfg(Cfg),
      .TAG_W(6),
      .XLEN(Cfg.XLEN)
  ) dut (
      .clk_i,
      .rst_ni,
      .csr_valid_i,
      .uop_i(uop),
      .rs1_data_i,
      .rob_tag_i('0),
      .interrupt_inject_i(1'b0),
      .async_exception_inject_i,
      .async_exception_cause_i,
      .async_exception_tval_i,
      .timer_irq_i(1'b0),
      .external_irq_i(1'b0),
      .trap_pc_i,
      .csr_valid_o,
      .csr_rob_tag_o(),
      .csr_result_o(),
      .csr_exception_o,
      .csr_ecause_o(),
      .csr_is_mispred_o,
      .csr_redirect_pc_o,
      .irq_trap_o(),
      .irq_trap_cause_o(),
      .irq_trap_pc_o(),
      .irq_trap_redirect_pc_o(),
      .satp_o(),
      .priv_mode_o,
      .mstatus_sum_o(),
      .mstatus_mxr_o(),
      .sfence_vma_flush_o()
  );

  assign dbg_mstatus_o = dut.csr_mstatus;
  assign dbg_medeleg_o = dut.csr_medeleg;
  assign dbg_sepc_o = dut.csr_sepc;
  assign dbg_scause_o = dut.csr_scause;
  assign dbg_stval_o = dut.csr_stval;

endmodule
