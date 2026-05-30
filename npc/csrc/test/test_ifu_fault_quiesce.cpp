#include "Vtb_ifu_fault_quiesce.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kUserPc = 0x95748000u;
constexpr uint32_t kNextUserPc = 0x95749000u;
constexpr uint32_t kTrapPc = 0xc00d3f20u;

void eval_low(Vtb_ifu_fault_quiesce &top) {
  top.clk_i = 0;
  top.eval();
}

void tick(Vtb_ifu_fault_quiesce &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
  top.clk_i = 0;
  top.eval();
}

void drive_defaults(Vtb_ifu_fault_quiesce &top) {
  top.bpu_pred_pc_i = kNextUserPc;
  top.flush_i = 0;
  top.redirect_pc_i = kTrapPc;
  top.mmu_satp_i = 0x80000001u;
  top.mmu_priv_i = 0;  // U-mode fetch.
  top.ifetch_fault_ready_i = 0;
  top.pte_rsp_valid_i = 0;
  top.pte_rsp_data_i = 0;
}

bool expect(bool cond, const char *msg, const Vtb_ifu_fault_quiesce &top) {
  if (cond) return true;
  std::cerr << "[FAIL] " << msg
            << " bpu_v=" << static_cast<uint32_t>(top.bpu_req_valid_o)
            << " bpu_r=" << static_cast<uint32_t>(top.bpu_req_ready_o)
            << " ic_v=" << static_cast<uint32_t>(top.icache_req_valid_o)
            << " pte_v=" << static_cast<uint32_t>(top.pte_req_valid_o)
            << " fault_v=" << static_cast<uint32_t>(top.ifetch_fault_valid_o)
            << " fault_pc=0x" << std::hex << top.ifetch_fault_pc_o
            << " bpu_pc=0x" << top.bpu_query_pc_o
            << " ic_addr=0x" << top.icache_req_addr_o
            << std::dec << "\n";
  return false;
}

bool wait_for_pte_request(Vtb_ifu_fault_quiesce &top) {
  for (int i = 0; i < 32; ++i) {
    eval_low(top);
    if (top.pte_req_valid_o) return true;
    tick(top);
  }
  return false;
}

bool wait_for_fault(Vtb_ifu_fault_quiesce &top) {
  for (int i = 0; i < 32; ++i) {
    eval_low(top);
    if (top.ifetch_fault_valid_o) return true;
    tick(top);
  }
  return false;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ifu_fault_quiesce top;

  drive_defaults(top);
  top.rst_i = 1;
  tick(top);
  tick(top);
  top.rst_i = 0;
  tick(top);

  top.flush_i = 1;
  top.redirect_pc_i = kUserPc;
  top.bpu_pred_pc_i = kNextUserPc;
  tick(top);
  top.flush_i = 0;

  if (!expect(wait_for_pte_request(top), "IFU should start a user instruction page walk", top)) return 1;

  // Return an invalid L1 PTE to force an instruction page fault.
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = 0;
  tick(top);
  top.pte_rsp_valid_i = 0;

  if (!expect(wait_for_fault(top), "IFU should report the instruction page fault", top)) return 1;
  if (!expect(top.ifetch_fault_pc_o == kUserPc, "fault PC should be the original user PC", top)) return 1;

  // Backend consumes the sideband fault, but the trap redirect flush has not arrived yet.
  top.ifetch_fault_ready_i = 1;
  tick(top);
  top.ifetch_fault_ready_i = 0;

  for (int i = 0; i < 8; ++i) {
    eval_low(top);
    if (!expect(!top.ifetch_fault_valid_o, "fault should be consumed before redirect", top)) return 1;
    if (!expect(!top.bpu_req_valid_o, "IFU must stop BPU enqueue while waiting for trap flush", top)) return 1;
    if (!expect(!top.icache_req_valid_o, "IFU must stop ICache issue while waiting for trap flush", top)) return 1;
    if (!expect(!top.pte_req_valid_o, "IFU must stop MMU walks while waiting for trap flush", top)) return 1;
    tick(top);
  }

  // The backend trap redirect releases the wait state and fetch can restart.
  top.mmu_priv_i = 3;  // Avoid needing a second page table setup in this unit test.
  top.flush_i = 1;
  top.redirect_pc_i = kTrapPc;
  top.bpu_pred_pc_i = kTrapPc + 4;
  tick(top);
  top.flush_i = 0;

  bool restarted = false;
  for (int i = 0; i < 8; ++i) {
    eval_low(top);
    restarted = restarted || top.bpu_req_valid_o || top.icache_req_valid_o;
    if (restarted) break;
    tick(top);
  }
  if (!expect(restarted, "IFU should restart after trap redirect flush", top)) return 1;

  std::cout << "[PASS] test_ifu_fault_quiesce\n";
  return 0;
}
