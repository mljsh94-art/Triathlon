#include "Vtb_csr_sret.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kPrivU = 0;
constexpr uint32_t kPrivS = 1;
constexpr uint32_t kPrivM = 3;
constexpr uint32_t kCsrMstatus = 0x300;
constexpr uint32_t kCsrMedeleg = 0x302;
constexpr uint32_t kCsrMepc = 0x341;
constexpr uint32_t kCsrStvec = 0x105;
constexpr uint32_t kUserPc = 0x95748da2u;
constexpr uint32_t kTrapVec = 0xc00d3f20u;
constexpr uint32_t kInstPageFault = 12;

void eval_low(Vtb_csr_sret &top) {
  top.clk_i = 0;
  top.eval();
}

void tick(Vtb_csr_sret &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
  top.clk_i = 0;
  top.eval();
}

void drive_nop(Vtb_csr_sret &top) {
  top.csr_valid_i = 0;
  top.op_i = 0;
  top.csr_addr_i = 0;
  top.rs1_data_i = 0;
  top.pc_i = 0;
  top.async_exception_inject_i = 0;
  top.async_exception_cause_i = 0;
  top.async_exception_tval_i = 0;
  top.trap_pc_i = 0;
}

void csrw(Vtb_csr_sret &top, uint32_t csr, uint32_t value, uint32_t pc = 0x80000000u) {
  drive_nop(top);
  top.csr_valid_i = 1;
  top.op_i = 1;
  top.csr_addr_i = csr;
  top.rs1_data_i = value;
  top.pc_i = pc;
  tick(top);
  drive_nop(top);
  tick(top);
}

bool exec_mret(Vtb_csr_sret &top) {
  drive_nop(top);
  top.csr_valid_i = 1;
  top.op_i = 2;
  top.pc_i = 0x80000080u;
  eval_low(top);
  const bool redirected = top.csr_is_mispred_o && top.csr_redirect_pc_o == kUserPc;
  tick(top);
  drive_nop(top);
  tick(top);
  return redirected;
}

bool exec_sret(Vtb_csr_sret &top) {
  drive_nop(top);
  top.csr_valid_i = 1;
  top.op_i = 3;
  top.pc_i = kTrapVec;
  eval_low(top);
  const bool redirected = top.csr_is_mispred_o && top.csr_redirect_pc_o == kUserPc;
  tick(top);
  drive_nop(top);
  tick(top);
  return redirected;
}

void inject_inst_page_fault(Vtb_csr_sret &top) {
  drive_nop(top);
  top.csr_valid_i = 1;
  top.async_exception_inject_i = 1;
  top.async_exception_cause_i = kInstPageFault;
  top.async_exception_tval_i = kUserPc;
  top.trap_pc_i = kUserPc;
  tick(top);
  drive_nop(top);
  tick(top);
}

bool expect(bool cond, const char *msg, const Vtb_csr_sret &top) {
  if (cond) return true;
  std::cerr << "[FAIL] " << msg
            << " priv=" << std::dec << static_cast<uint32_t>(top.priv_mode_o)
            << " mstatus=0x" << std::hex << top.dbg_mstatus_o
            << " medeleg=0x" << top.dbg_medeleg_o
            << " sepc=0x" << top.dbg_sepc_o
            << " scause=0x" << top.dbg_scause_o
            << " stval=0x" << top.dbg_stval_o
            << " redirect=0x" << top.csr_redirect_pc_o
            << std::dec << "\n";
  return false;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_csr_sret top;

  drive_nop(top);
  top.rst_ni = 0;
  tick(top);
  tick(top);
  top.rst_ni = 1;
  tick(top);

  if (!expect(top.priv_mode_o == kPrivM, "reset should enter M-mode", top)) return 1;

  // Delegate instruction page faults to S-mode, then mret into U-mode.
  csrw(top, kCsrMedeleg, 1u << kInstPageFault);
  csrw(top, kCsrStvec, kTrapVec);
  csrw(top, kCsrMepc, kUserPc);
  csrw(top, kCsrMstatus, 0u);  // MPP=U
  if (!expect(exec_mret(top), "mret should redirect to user PC", top)) return 1;
  if (!expect(top.priv_mode_o == kPrivU, "mret with MPP=U should enter U-mode", top)) return 1;

  // A U-mode instruction page fault should trap to S, record SPP=0, then sret back to U.
  inject_inst_page_fault(top);
  if (!expect(top.priv_mode_o == kPrivS, "delegated U-mode instruction page fault should enter S-mode", top)) return 1;
  if (!expect(top.dbg_sepc_o == kUserPc, "trap should record sepc=user PC", top)) return 1;
  if (!expect((top.dbg_mstatus_o & 0x100u) == 0, "trap from U should leave mstatus.SPP=0", top)) return 1;

  if (!expect(exec_sret(top), "sret should redirect to sepc", top)) return 1;
  if (!expect(top.priv_mode_o == kPrivU, "sret with SPP=0 should return to U-mode", top)) return 1;
  if (!expect((top.dbg_mstatus_o & 0x100u) == 0, "sret should clear SPP", top)) return 1;

  std::cout << "[PASS] test_csr_sret\n";
  return 0;
}
