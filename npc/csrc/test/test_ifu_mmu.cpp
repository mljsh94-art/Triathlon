#include "Vtb_ifu_mmu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr uint32_t kPrivS = 1u;
constexpr uint32_t kSatpModeSv32 = 0x80000000u;
constexpr uint32_t kRootTablePa = 0x00100000u;
constexpr uint32_t kL0TablePa = 0x00101000u;
constexpr uint32_t kInstPageFault = 12u;

void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cerr << "[FAIL] " << msg << "\n";
    std::exit(1);
  }
}

void eval_comb(Vtb_ifu_mmu *top) {
  top->clk_i = 0;
  top->eval();
}

void tick(Vtb_ifu_mmu *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

void clear_inputs(Vtb_ifu_mmu *top) {
  top->flush_i = 0;
  top->redirect_pc_i = 0;

  top->bpu_valid_i = 0;
  top->bpu_fetch_pc_i = 0;
  top->bpu_predicted_pc_i = 0;
  top->bpu_pred_slot_valid_i = 0;
  top->bpu_pred_slot_idx_i = 0;
  top->bpu_pred_target_i = 0;

  top->icache_req_ready_i = 1;
  top->icache_rsp_valid_i = 0;
  for (int i = 0; i < 4; i++) {
    top->icache_rsp_data_i[i] = 0;
  }

  top->pte_req_ready_i = 1;
  top->pte_rsp_valid_i = 0;
  top->pte_rsp_data_i = 0;
  top->pte_upd_ready_i = 1;

  top->ifetch_fault_ready_i = 1;
  top->mmu_satp_i = 0;
  top->mmu_priv_i = 3;
  top->mmu_sum_i = 0;
  top->mmu_mxr_i = 0;
  top->mmu_sfence_vma_i = 0;
}

void reset(Vtb_ifu_mmu *top) {
  clear_inputs(top);
  top->rst_i = 1;
  tick(top);
  tick(top);
  top->rst_i = 0;
  tick(top);
}

uint32_t make_nonleaf_pte(uint32_t next_table_pa) {
  return ((next_table_pa >> 12) << 10) | 0x1u;
}

uint32_t make_exec_leaf_pte(uint32_t pa) {
  constexpr uint32_t kPteV = 1u << 0;
  constexpr uint32_t kPteX = 1u << 3;
  constexpr uint32_t kPteA = 1u << 6;
  return ((pa >> 12) << 10) | kPteV | kPteX | kPteA;
}

void feed_pte_rsp(Vtb_ifu_mmu *top, uint32_t pte) {
  top->pte_rsp_valid_i = 1;
  top->pte_rsp_data_i = pte;
  tick(top);
  top->pte_rsp_valid_i = 0;
}

void issue_fetch_req(Vtb_ifu_mmu *top, uint32_t fetch_pc, uint32_t next_pc) {
  top->bpu_fetch_pc_i = fetch_pc;
  top->bpu_predicted_pc_i = next_pc;
  top->bpu_pred_slot_valid_i = 0;
  top->bpu_pred_slot_idx_i = 0;
  top->bpu_pred_target_i = 0;
  top->bpu_valid_i = 1;
  bool fired = false;
  for (int i = 0; i < 20; i++) {
    eval_comb(top);
    if (top->bpu_fire_o) {
      tick(top);
      fired = true;
      break;
    }
    tick(top);
  }
  top->bpu_valid_i = 0;
  expect(fired, "issue_fetch_req: IFU did not accept BPU request");
}

void redirect_pc(Vtb_ifu_mmu *top, uint32_t pc) {
  top->flush_i = 1;
  top->redirect_pc_i = pc;
  tick(top);
  top->flush_i = 0;
  top->redirect_pc_i = 0;
}

bool wait_pte_req(Vtb_ifu_mmu *top, uint32_t expect_paddr, int max_cycles, const char *tag) {
  for (int i = 0; i < max_cycles; i++) {
    eval_comb(top);
    if (top->pte_req_valid_o) {
      if (top->pte_req_paddr_o != expect_paddr) {
        std::cerr << "[FAIL] " << tag << ": pte_req_paddr got=0x" << std::hex
                  << top->pte_req_paddr_o << " expect=0x" << expect_paddr << std::dec << "\n";
        std::exit(1);
      }
      return true;
    }
    tick(top);
  }
  return false;
}

bool wait_icache_req(Vtb_ifu_mmu *top, uint32_t expect_paddr, int max_cycles) {
  for (int i = 0; i < max_cycles; i++) {
    eval_comb(top);
    if (top->icache_req_valid_o) {
      if (top->icache_req_addr_o != expect_paddr) {
        std::cerr << "[FAIL] icache_req addr got=0x" << std::hex
                  << top->icache_req_addr_o << " expect=0x" << expect_paddr << std::dec << "\n";
        std::exit(1);
      }
      return true;
    }
    tick(top);
  }
  return false;
}

void test_ifetch_translation_and_fault(Vtb_ifu_mmu *top) {
  const uint32_t satp = kSatpModeSv32 | ((kRootTablePa >> 12) & 0x003fffffu);
  top->mmu_satp_i = satp;
  top->mmu_priv_i = kPrivS;
  top->mmu_sum_i = 0;
  top->mmu_mxr_i = 0;

  // Case 1: valid translation => translated paddr reaches ICache request.
  const uint32_t va_ok = 0x80400000u;
  const uint32_t pa_ok = 0x20000000u;
  const uint32_t vpn1_ok = (va_ok >> 22) & 0x3ffu;
  const uint32_t vpn0_ok = (va_ok >> 12) & 0x3ffu;
  const uint32_t l1_pte_addr_ok = kRootTablePa + (vpn1_ok * 4u);
  const uint32_t l0_pte_addr_ok = kL0TablePa + (vpn0_ok * 4u);

  redirect_pc(top, va_ok);
  issue_fetch_req(top, va_ok, va_ok + 4u);
  expect(wait_pte_req(top, l1_pte_addr_ok, 40, "l1 walk"),
         "MMU did not issue L1 PTE request");
  feed_pte_rsp(top, make_nonleaf_pte(kL0TablePa));

  expect(wait_pte_req(top, l0_pte_addr_ok, 40, "l0 walk"),
         "MMU did not issue L0 PTE request");
  feed_pte_rsp(top, make_exec_leaf_pte(pa_ok));

  expect(wait_icache_req(top, pa_ok, 40), "translated icache request not observed");
  expect(top->ifetch_fault_valid_o == 0, "fault should stay low for valid mapping");

  // Case 2: invalid PTE => instruction page fault sideband.
  const uint32_t va_fault = 0x80800000u;
  const uint32_t vpn1_fault = (va_fault >> 22) & 0x3ffu;
  const uint32_t l1_pte_addr_fault = kRootTablePa + (vpn1_fault * 4u);

  redirect_pc(top, va_fault);
  issue_fetch_req(top, va_fault, va_fault + 4u);
  expect(wait_pte_req(top, l1_pte_addr_fault, 40, "fault l1 walk"),
         "fault case: MMU did not issue L1 request");
  feed_pte_rsp(top, 0u);  // Invalid PTE

  bool seen_fault = false;
  for (int i = 0; i < 40; i++) {
    eval_comb(top);
    if (top->ifetch_fault_valid_o) {
      seen_fault = true;
      expect(top->ifetch_fault_cause_o == kInstPageFault, "fault cause must be instruction page fault");
      expect(top->ifetch_fault_pc_o == va_fault, "fault pc must equal faulting fetch vaddr");
      expect(top->ifetch_fault_tval_o == va_fault, "fault tval must equal faulting fetch vaddr");
      tick(top);
      break;
    }
    tick(top);
  }
  expect(seen_fault, "instruction page fault sideband not observed");
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_ifu_mmu;
  reset(top);
  test_ifetch_translation_and_fault(top);
  std::cout << "--- ALL TESTS PASSED ---\n";
  delete top;
  return 0;
}
