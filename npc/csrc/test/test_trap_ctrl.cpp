#include "Vtb_trap_ctrl.h"
#include "verilated.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kMtvec = 0x305u;
constexpr uint32_t kMepc = 0x341u;
constexpr uint8_t kCsrRw = 0u;

void tick(Vtb_trap_ctrl &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
}

void clear_inputs(Vtb_trap_ctrl &top) {
  top.valid_i = 0;
  top.is_csr_i = 0;
  top.is_ecall_i = 0;
  top.is_ebreak_i = 0;
  top.is_mret_i = 0;
  top.is_sret_i = 0;
  top.is_wfi_i = 0;
  top.csr_addr_i = 0;
  top.csr_op_i = 0;
  top.rs1_idx_i = 0;
  top.rs1_data_i = 0;
  top.rob_tag_i = 0;
}

void csr_rw(Vtb_trap_ctrl &top, uint32_t addr, uint32_t data, uint8_t rob_tag = 1) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_csr_i = 1;
  top.csr_addr_i = addr;
  top.csr_op_i = kCsrRw;
  top.rs1_idx_i = 1;
  top.rs1_data_i = data;
  top.rob_tag_i = rob_tag;
  tick(top);
  clear_inputs(top);
  tick(top);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_trap_ctrl top;

  clear_inputs(top);
  top.rst_ni = 0;
  tick(top);
  top.rst_ni = 1;
  tick(top);

  csr_rw(top, kMtvec, 0x80000100u);

  clear_inputs(top);
  top.valid_i = 1;
  top.is_ecall_i = 1;
  top.rob_tag_i = 0x12;
  top.eval();

  assert(top.wb_valid_o == 1);
  assert(top.wb_tag_o == 0x12);
  assert(top.wb_exception_o == 1);
  assert(top.wb_ecause_o == 11);
  assert(top.wb_is_mispred_o == 0);
  assert(top.wb_redirect_pc_o == 0x80000100u);

  clear_inputs(top);
  top.valid_i = 1;
  top.is_ebreak_i = 1;
  top.rob_tag_i = 0x13;
  top.eval();

  assert(top.wb_valid_o == 1);
  assert(top.wb_tag_o == 0x13);
  assert(top.wb_exception_o == 1);
  assert(top.wb_ecause_o == 3);
  assert(top.wb_is_mispred_o == 0);
  assert(top.wb_redirect_pc_o == 0x80000100u);

  csr_rw(top, kMepc, 0x80002000u);

  clear_inputs(top);
  top.valid_i = 1;
  top.is_mret_i = 1;
  top.rob_tag_i = 0x16;
  top.eval();

  assert(top.wb_valid_o == 1);
  assert(top.wb_tag_o == 0x16);
  assert(top.wb_exception_o == 0);
  assert(top.wb_is_mispred_o == 1);
  assert(top.wb_redirect_pc_o == 0x80002000u);

  clear_inputs(top);
  top.valid_i = 1;
  top.is_wfi_i = 1;
  top.rob_tag_i = 0x1a;
  top.eval();

  assert(top.wb_valid_o == 1);
  assert(top.wb_tag_o == 0x1a);
  assert(top.wb_exception_o == 0);
  assert(top.wb_is_mispred_o == 0);
  assert(top.wb_redirect_pc_o == 0u);

  std::cout << "[PASS] test_trap_ctrl" << std::endl;
  return 0;
}
