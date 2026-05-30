#include "Vtb_sv32_mmu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr uint32_t kSatpModeSv32 = 0x80000000u;
constexpr uint32_t kRootPpn = 0x00080010u;  // root table at 0x80010000
constexpr uint32_t kSatp = kSatpModeSv32 | kRootPpn;

constexpr uint32_t kVa = 0x40000123u;
constexpr uint32_t kVpn1 = (kVa >> 22) & 0x3ffu;
constexpr uint32_t kVpn0 = (kVa >> 12) & 0x3ffu;
constexpr uint32_t kPageOff = kVa & 0xfffu;

constexpr uint32_t kL1Ppn = 0x00080020u;       // l1 table at 0x80020000
constexpr uint32_t kLeafPpn = 0x00080030u;     // mapped page at 0x80030000
constexpr uint32_t kRootBase = kRootPpn << 12; // physical
constexpr uint32_t kL1Base = kL1Ppn << 12;
constexpr uint32_t kLeafPteAddr = kL1Base + (kVpn0 << 2);

constexpr uint32_t kPteV = 1u << 0;
constexpr uint32_t kPteR = 1u << 1;
constexpr uint32_t kPteW = 1u << 2;
constexpr uint32_t kPteX = 1u << 3;
constexpr uint32_t kPteU = 1u << 4;
constexpr uint32_t kPteA = 1u << 6;
constexpr uint32_t kPteD = 1u << 7;

constexpr uint32_t kPtrPte = (kL1Ppn << 10) | kPteV;
constexpr uint32_t kLeafRwAd = (kLeafPpn << 10) | kPteV | kPteR | kPteW | kPteA | kPteD;
constexpr uint32_t kLeafUad = (kLeafPpn << 10) | kPteV | kPteR | kPteU | kPteA | kPteD;
constexpr uint32_t kLeafXOnlyAd = (kLeafPpn << 10) | kPteV | kPteX | kPteA | kPteD;
constexpr uint32_t kLeafNeedA = (kLeafPpn << 10) | kPteV | kPteR | kPteW | kPteD;
constexpr uint32_t kLeafNeedD = (kLeafPpn << 10) | kPteV | kPteR | kPteW | kPteA;

constexpr uint32_t kPrivU = 0u;
constexpr uint32_t kPrivS = 1u;
constexpr uint32_t kAccessInstr = 0u;
constexpr uint32_t kAccessLoad = 1u;
constexpr uint32_t kAccessStore = 2u;

void tick(Vtb_sv32_mmu &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
}

[[noreturn]] void fail(const char *msg) {
  std::cerr << "[FAIL] " << msg << "\n";
  std::exit(1);
}

void expect(bool cond, const char *msg) {
  if (!cond) fail(msg);
}

void clear_inputs(Vtb_sv32_mmu &top) {
  top.req_valid_i = 0;
  top.req_vaddr_i = 0;
  top.req_access_i = 0;
  top.req_priv_i = kPrivS;
  top.req_sum_i = 0;
  top.req_mxr_i = 0;
  top.satp_i = 0;
  top.sfence_vma_i = 0;
  top.pte_req_ready_i = 1;
  top.pte_rsp_valid_i = 0;
  top.pte_rsp_data_i = 0;
  top.pte_upd_ready_i = 1;
}

void issue_req(Vtb_sv32_mmu &top, uint32_t vaddr, uint32_t access, uint32_t priv, bool sum, bool mxr,
               uint32_t satp) {
  top.req_valid_i = 1;
  top.req_vaddr_i = vaddr;
  top.req_access_i = access;
  top.req_priv_i = priv;
  top.req_sum_i = sum ? 1 : 0;
  top.req_mxr_i = mxr ? 1 : 0;
  top.satp_i = satp;
  top.eval();
  for (int i = 0; !top.req_ready_o && i < 4; i++) {
    tick(top);
    top.eval();
  }
  expect(top.req_ready_o, "request should be accepted only when req_ready_o=1");
  tick(top);
  top.req_valid_i = 0;
}

void expect_walk_l1(Vtb_sv32_mmu &top) {
  expect(top.pte_req_valid_o, "walk should issue l1 pte request");
  expect(top.pte_req_paddr_o == (kRootBase + (kVpn1 << 2)), "l1 pte address mismatch");
}

void feed_l1_ptr(Vtb_sv32_mmu &top) {
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = kPtrPte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);
  expect(top.pte_req_valid_o, "walk should issue l0 pte request");
  expect(top.pte_req_paddr_o == kLeafPteAddr, "l0 pte address mismatch");
}

void feed_l0_leaf(Vtb_sv32_mmu &top, uint32_t leaf_pte) {
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = leaf_pte;
  tick(top);
  top.pte_rsp_valid_i = 0;
}

void expect_translate_ok(Vtb_sv32_mmu &top) {
  expect(top.resp_valid_o, "translation response should be valid");
  expect(!top.resp_page_fault_o, "translation should not page fault");
  expect(top.resp_paddr_o == ((kLeafPpn << 12) | kPageOff), "translated PA mismatch");
}

void expect_translate_fault(Vtb_sv32_mmu &top) {
  expect(top.resp_valid_o, "fault response should be valid");
  expect(top.resp_page_fault_o, "translation should page fault");
}

void do_walk_leaf(Vtb_sv32_mmu &top, uint32_t access, uint32_t priv, bool sum, bool mxr, uint32_t leaf_pte) {
  issue_req(top, kVa, access, priv, sum, mxr, kSatp);
  expect_walk_l1(top);
  feed_l1_ptr(top);
  feed_l0_leaf(top, leaf_pte);
}

void sfence_flush(Vtb_sv32_mmu &top) {
  top.sfence_vma_i = 1;
  tick(top);
  top.sfence_vma_i = 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_sv32_mmu top;

  top.rst_ni = 0;
  clear_inputs(top);
  tick(top);
  top.rst_ni = 1;
  tick(top);

  // Case 1: miss walk success.
  do_walk_leaf(top, kAccessLoad, kPrivS, false, false, kLeafRwAd);
  expect_translate_ok(top);

  // Case 2: TLB hit should avoid a second walk.
  issue_req(top, kVa, kAccessLoad, kPrivS, false, false, kSatp);
  expect(top.resp_valid_o, "tlb hit should return response");
  expect(!top.resp_page_fault_o, "tlb hit should not fault");
  expect(!top.pte_req_valid_o, "tlb hit should not request pte");

  // Case 3: sfence.vma should flush TLB and force new walk.
  top.sfence_vma_i = 1;
  tick(top);
  top.sfence_vma_i = 0;
  issue_req(top, kVa, kAccessLoad, kPrivS, false, false, kSatp);
  expect_walk_l1(top);
  feed_l1_ptr(top);
  feed_l0_leaf(top, kLeafRwAd);
  expect_translate_ok(top);

  // Case 4: U-mode cannot access supervisor page (U=0).
  sfence_flush(top);
  do_walk_leaf(top, kAccessLoad, kPrivU, false, false, kLeafRwAd);
  expect_translate_fault(top);

  // Case 5: S-mode load to U page requires SUM=1.
  sfence_flush(top);
  do_walk_leaf(top, kAccessLoad, kPrivS, false, false, kLeafUad);
  expect_translate_fault(top);

  sfence_flush(top);
  do_walk_leaf(top, kAccessLoad, kPrivS, true, false, kLeafUad);
  expect_translate_ok(top);

  // Case 6: MXR allows loading X-only pages.
  sfence_flush(top);
  do_walk_leaf(top, kAccessLoad, kPrivS, false, false, kLeafXOnlyAd);
  expect_translate_fault(top);

  sfence_flush(top);
  do_walk_leaf(top, kAccessLoad, kPrivS, false, true, kLeafXOnlyAd);
  expect_translate_ok(top);

  // Case 7: A bit auto-set on leaf.
  sfence_flush(top);
  do_walk_leaf(top, kAccessLoad, kPrivS, false, false, kLeafNeedA);
  expect(top.pte_upd_valid_o, "A=0 should request PTE update");
  expect(top.pte_upd_paddr_o == kLeafPteAddr, "A update paddr mismatch");
  expect((top.pte_upd_data_o & kPteA) != 0, "A update should set A bit");
  tick(top);
  expect_translate_ok(top);

  // Case 8: D bit auto-set on store leaf.
  sfence_flush(top);
  do_walk_leaf(top, kAccessStore, kPrivS, false, false, kLeafNeedD);
  expect(top.pte_upd_valid_o, "D=0 on store should request PTE update");
  expect(top.pte_upd_paddr_o == kLeafPteAddr, "D update paddr mismatch");
  expect((top.pte_upd_data_o & kPteD) != 0, "D update should set D bit");
  tick(top);
  expect_translate_ok(top);

  std::cout << "[PASS] test_sv32_mmu" << std::endl;
  return 0;
}
