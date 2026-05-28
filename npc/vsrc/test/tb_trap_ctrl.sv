import config_pkg::*;
import decode_pkg::*;

module tb_trap_ctrl #(
    parameter config_pkg::cfg_t Cfg = global_config_pkg::Cfg,
    parameter int unsigned TAG_W = 6
) (
    input logic clk_i,
    input logic rst_ni,

    input logic valid_i,
    input logic is_csr_i,
    input logic is_ecall_i,
    input logic is_ebreak_i,
    input logic is_mret_i,
    input logic is_sret_i,
    input logic is_wfi_i,
    input logic [11:0] csr_addr_i,
    input logic [2:0] csr_op_i,
    input logic [4:0] rs1_idx_i,
    input logic [Cfg.XLEN-1:0] rs1_data_i,
    input logic [TAG_W-1:0] rob_tag_i,

    output logic wb_valid_o,
    output logic [TAG_W-1:0] wb_tag_o,
    output logic [Cfg.XLEN-1:0] wb_data_o,
    output logic wb_exception_o,
    output logic [4:0] wb_ecause_o,
    output logic wb_is_mispred_o,
    output logic [Cfg.PLEN-1:0] wb_redirect_pc_o
);

  decode_pkg::uop_t uop;

  always_comb begin
    uop = '0;
    uop.valid = valid_i;
    uop.fu = decode_pkg::FU_CSR;
    uop.is_csr = is_csr_i;
    uop.is_ecall = is_ecall_i;
    uop.is_ebreak = is_ebreak_i;
    uop.is_mret = is_mret_i;
    uop.is_sret = is_sret_i;
    uop.is_wfi = is_wfi_i;
    uop.csr_addr = csr_addr_i;
    uop.csr_op = decode_pkg::csr_op_e'(csr_op_i);
    uop.rs1 = rs1_idx_i;
  end

  execute_csr #(
      .Cfg(Cfg),
      .TAG_W(TAG_W),
      .XLEN(Cfg.XLEN)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .csr_valid_i(valid_i),
      .uop_i(uop),
      .rs1_data_i(rs1_data_i),
      .rob_tag_i(rob_tag_i),
      .interrupt_inject_i(1'b0),
      .async_exception_inject_i(1'b0),
      .async_exception_cause_i('0),
      .async_exception_tval_i('0),
      .timer_irq_i(1'b0),
      .external_irq_i(1'b0),
      .trap_pc_i('0),
      .csr_valid_o(wb_valid_o),
      .csr_rob_tag_o(wb_tag_o),
      .csr_result_o(wb_data_o),
      .csr_exception_o(wb_exception_o),
      .csr_ecause_o(wb_ecause_o),
      .csr_is_mispred_o(wb_is_mispred_o),
      .csr_redirect_pc_o(wb_redirect_pc_o),
      .irq_trap_o(),
      .irq_trap_cause_o(),
      .irq_trap_pc_o(),
      .irq_trap_redirect_pc_o()
  );

endmodule
