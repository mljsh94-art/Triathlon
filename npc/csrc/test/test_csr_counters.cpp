#include "Vtb_privilege_csr.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr uint32_t kCsrRs = 1u;
constexpr uint32_t kCycle = 0xC00u;
constexpr uint32_t kTime = 0xC01u;
constexpr uint32_t kInstret = 0xC02u;
constexpr uint32_t kCycleh = 0xC80u;
constexpr uint32_t kTimeh = 0xC81u;
constexpr uint32_t kInstreth = 0xC82u;

struct Resp {
  uint32_t data = 0;
  bool exception = false;
};

void tick(Vtb_privilege_csr &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
}

void clear_inputs(Vtb_privilege_csr &top) {
  top.valid_i = 0;
  top.is_csr_i = 0;
  top.is_ecall_i = 0;
  top.is_ebreak_i = 0;
  top.is_mret_i = 0;
  top.is_sret_i = 0;
  top.is_wfi_i = 0;
  top.is_sfence_vma_i = 0;
  top.uop_pc_i = 0;
  top.csr_addr_i = 0;
  top.csr_op_i = 0;
  top.rs1_idx_i = 0;
  top.rs1_data_i = 0;
  top.rob_tag_i = 0;
  top.async_exception_inject_i = 0;
  top.async_exception_cause_i = 0;
  top.async_exception_tval_i = 0;
  top.trap_pc_i = 0;
}

Resp csr_read(Vtb_privilege_csr &top, uint32_t csr) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_csr_i = 1;
  top.csr_addr_i = csr;
  top.csr_op_i = kCsrRs;
  top.rs1_idx_i = 0;
  top.eval();
  Resp r{top.wb_data_o, static_cast<bool>(top.wb_exception_o)};
  tick(top);
  clear_inputs(top);
  tick(top);
  return r;
}

void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cerr << "[FAIL] " << msg << "\n";
    std::exit(1);
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_privilege_csr top;

  clear_inputs(top);
  top.rst_ni = 0;
  tick(top);
  top.rst_ni = 1;
  tick(top);

  expect(!csr_read(top, kCycle).exception, "cycle read should not trap");
  expect(!csr_read(top, kInstret).exception, "instret read should not trap");
  expect(!csr_read(top, kCycleh).exception, "cycleh read should not trap");
  expect(!csr_read(top, kTimeh).exception, "timeh read should not trap");
  expect(!csr_read(top, kInstreth).exception, "instreth read should not trap");

  Resp t0 = csr_read(top, kTime);
  Resp t1 = csr_read(top, kTime);
  expect(!t0.exception && !t1.exception, "time reads should not trap");
  expect(t0.data != 0, "time should not be stuck at zero after reset");
  expect(t1.data > t0.data, "time should advance between reads");

  std::cout << "[PASS] test_csr_counters" << std::endl;
  return 0;
}
