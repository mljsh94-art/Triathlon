#include "Vtb_lsu.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>

#define ANSI_RES_GRN "\x1b[32m"
#define ANSI_RES_RED "\x1b[31m"
#define ANSI_RES_RST "\x1b[0m"

static void tick(Vtb_lsu *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

static void eval_comb(Vtb_lsu *top) {
  top->clk_i = 0;
  top->eval();
}

static void reset(Vtb_lsu *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  tick(top);
  tick(top);
  top->rst_ni = 1;
  tick(top);
}

static void set_defaults(Vtb_lsu *top) {
  top->flush_i = 0;
  top->req_valid_i = 0;
  top->is_load_i = 0;
  top->is_store_i = 0;
  top->lsu_op_i = 0;
  top->amo_op_i = 0;
  top->imm_i = 0;
  top->rs1_data_i = 0;
  top->rs2_data_i = 0;
  top->rob_tag_i = 0;
  top->st_id_i = 0;
  top->mmu_satp_i = 0;
  top->mmu_priv_i = 1;
  top->mmu_sum_i = 0;
  top->mmu_mxr_i = 0;
  top->mmu_sfence_vma_i = 0;

  top->stq_fwd_hit_i = 0;
  top->stq_fwd_data_i = 0;

  top->ld_req_ready_i = 0;
  top->ld_rsp_valid_i = 0;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0;
  top->ld_rsp_err_i = 0;
  top->pte_req_ready_i = 1;
  top->pte_rsp_valid_i = 0;
  top->pte_rsp_data_i = 0;
  top->pte_upd_ready_i = 1;

  top->wb_ready_i = 1;

  top->lq_test_alloc_valid_i = 0;
  top->lq_test_alloc_rob_tag_i = 0;
  top->lq_test_commit_valid_i = 0;
  top->lq_test_commit_rob_idx_i = 0;

  // Keep each test deterministic even when LSU arbiters use round-robin state.
  top->flush_i = 1;
  tick(top);
  top->flush_i = 0;
  eval_comb(top);
}

static void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cout << "[ " << ANSI_RES_RED << "FAIL" << ANSI_RES_RST << " ] " << msg << "\n";
    std::exit(1);
  } else {
    std::cout << "[ " << ANSI_RES_GRN << "PASS" << ANSI_RES_RST << " ] " << msg << "\n";
  }
}

enum {
  LSU_LB = 0,
  LSU_LH = 1,
  LSU_LW = 2,
  LSU_LD = 3,
  LSU_LBU = 4,
  LSU_LHU = 5,
  LSU_LWU = 6,
  LSU_SB = 7,
  LSU_SH = 8,
  LSU_SW = 9,
  LSU_SD = 10,
  LSU_LR = 11,
  LSU_SC = 12,
  LSU_SC_FAIL = 13,
  LSU_AMO = 14
};

enum {
  AMO_NONE = 0,
  AMO_SWAP = 1,
  AMO_ADD = 2,
  AMO_XOR = 3,
  AMO_AND = 4,
  AMO_OR = 5,
  AMO_MIN = 6,
  AMO_MAX = 7,
  AMO_MINU = 8,
  AMO_MAXU = 9
};

static constexpr uint32_t kPrivU = 0;
static constexpr uint32_t kPrivS = 1;
static constexpr uint32_t kSatpSv32Root = 0x80000000u | ((0x00100000u >> 12) & 0x003fffffu);
// Cacheable DRAM base (config_pkg::PMEM_BASE). Load/AMO D$ tests must use
// addresses here; below this range is MMIO and routes to uncached path.
static constexpr uint32_t kPmemBase = 0x80000000u;
static constexpr uint32_t pmem_addr(uint32_t off) { return kPmemBase + off; }

static constexpr uint32_t kPteV = 1u << 0;
static constexpr uint32_t kPteR = 1u << 1;
static constexpr uint32_t kPteW = 1u << 2;
static constexpr uint32_t kPteX = 1u << 3;
static constexpr uint32_t kPteA = 1u << 6;
static constexpr uint32_t kPteD = 1u << 7;

static uint32_t make_leaf_pte(uint32_t pa, uint32_t perm) {
  return ((pa >> 12) << 10) | perm | kPteV;
}

static uint32_t satp_root_pa(uint32_t satp) { return (satp & 0x003fffffu) << 12; }
static uint32_t vpn1(uint32_t vaddr) { return (vaddr >> 22) & 0x3ffu; }
static uint32_t vpn0(uint32_t vaddr) { return (vaddr >> 12) & 0x3ffu; }

static void wait_pte_req(Vtb_lsu *top, uint32_t expect_paddr, const char *msg) {
  for (int i = 0; i < 20; i++) {
    eval_comb(top);
    if (top->pte_req_valid_o) {
      expect(top->pte_req_paddr_o == expect_paddr, msg);
      return;
    }
    tick(top);
  }
  expect(false, "MMU walk timeout waiting pte_req");
}

static void feed_pte_rsp(Vtb_lsu *top, uint32_t pte) {
  top->pte_rsp_valid_i = 1;
  top->pte_rsp_data_i = pte;
  tick(top);
  top->pte_rsp_valid_i = 0;
}

static void test_store_aligned(Vtb_lsu *top) {
  set_defaults(top);
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x1000;
  top->imm_i = 4;
  top->rs2_data_i = 0xA5A5A5A5;
  top->rob_tag_i = 0x3;
  top->st_id_i = 0x5;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Store aligned: req_ready");
  expect(top->st_ex_valid_o == 1, "Store aligned: st_ex_valid");
  expect(top->st_ex_addr_o == 0x1004, "Store aligned: st_ex_addr");
  expect(top->st_ex_data_o == 0xA5A5A5A5, "Store aligned: st_ex_data");
  expect(top->st_ex_st_id_o == 0x5, "Store aligned: st_ex_st_id");

  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Store aligned: wb_valid");
  expect(top->wb_exception_o == 0, "Store aligned: wb_exception");
  expect(top->wb_rob_idx_o == 0x3, "Store aligned: wb_rob_idx");

  tick(top);
}

static void test_store_misaligned(Vtb_lsu *top) {
  set_defaults(top);
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x1000;
  top->imm_i = 2; // misaligned for SW
  top->rs2_data_i = 0x11111111;
  top->rob_tag_i = 0x4;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Store misaligned: req_ready");
  expect(top->st_ex_valid_o == 0, "Store misaligned: st_ex_valid should be 0");

  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Store misaligned: wb_valid");
  expect(top->wb_exception_o == 1, "Store misaligned: wb_exception");
  expect(top->wb_ecause_o == 6, "Store misaligned: ecause=6");

  tick(top);
}

static void test_load_forward_lb(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LB;
  top->rs1_data_i = pmem_addr(0x2000);
  top->imm_i = 0;
  top->rob_tag_i = 0x7;
  top->stq_fwd_hit_i = 1;
  top->stq_fwd_data_i = 0x00000080; // sign-extend to 0xFFFFFF80
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load fwd LB: req_ready");
  expect(top->stq_fwd_addr_o == pmem_addr(0x2000), "Load fwd LB: stq_fwd_addr");

  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Load fwd LB: wb_valid");
  expect(top->wb_exception_o == 0, "Load fwd LB: wb_exception");
  expect(top->wb_data_o == 0xFFFFFF80u, "Load fwd LB: wb_data sign-extend");

  tick(top);
}

static void test_load_dcache_ok(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x3000);
  top->imm_i = 4;
  top->rob_tag_i = 0x9;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load D$ ok: req_ready");

  tick(top); // accept request -> S_LD_REQ
  top->req_valid_i = 0;

  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "Load D$ ok: ld_req_valid");
  expect(top->ld_req_addr_o == pmem_addr(0x3004), "Load D$ ok: ld_req_addr");
  expect(top->ld_req_op_o == LSU_LW, "Load D$ ok: ld_req_op");

  tick(top); // move to S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0x12345678;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "Load D$ ok: ld_rsp_ready");
  expect(top->wb_valid_o == 1, "Load D$ ok: wb_valid");
  expect(top->wb_exception_o == 0, "Load D$ ok: wb_exception");
  expect(top->wb_data_o == 0x12345678, "Load D$ ok: wb_data");

  tick(top); // response consumed
  top->ld_rsp_valid_i = 0;
}

static void test_load_misaligned(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x3000);
  top->imm_i = 2; // misaligned for LW
  top->rob_tag_i = 0xA;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load misaligned: req_ready");

  tick(top); // S_RESP
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Load misaligned: wb_valid");
  expect(top->wb_exception_o == 1, "Load misaligned: wb_exception");
  expect(top->wb_ecause_o == 4, "Load misaligned: ecause=4");
  expect(top->ld_req_valid_o == 0, "Load misaligned: no dcache req");

  tick(top);
}

static void test_load_access_fault(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x4000);
  top->imm_i = 0;
  top->rob_tag_i = 0xB;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load access fault: req_ready");

  tick(top); // S_LD_REQ
  top->req_valid_i = 0;

  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "Load access fault: ld_req_valid");

  tick(top); // S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0xDEADBEEF;
  top->ld_rsp_err_i = 1;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "Load access fault: ld_rsp_ready");
  expect(top->wb_valid_o == 1, "Load access fault: wb_valid");
  expect(top->wb_exception_o == 1, "Load access fault: wb_exception");
  expect(top->wb_ecause_o == 5, "Load access fault: ecause=5");
  expect(top->wb_data_o == pmem_addr(0x4000), "Load access fault: wb_data carries fault address");

  tick(top); // response consumed
  top->ld_rsp_valid_i = 0;
}

static void test_mmu_load_page_fault(Vtb_lsu *top) {
  set_defaults(top);
  const uint32_t vaddr = 0x80403000u;
  const uint32_t l0_table_pa = 0x00102000u;
  const uint32_t root_pa = satp_root_pa(kSatpSv32Root);
  const uint32_t l1_addr = root_pa + vpn1(vaddr) * 4u;
  const uint32_t l0_addr = l0_table_pa + vpn0(vaddr) * 4u;
  const uint32_t l1_ptr_pte = ((l0_table_pa >> 12) << 10) | kPteV;
  const uint32_t l0_leaf_xonly = make_leaf_pte(0x80003000u, kPteX | kPteA | kPteD);

  top->mmu_satp_i = kSatpSv32Root;
  top->mmu_priv_i = kPrivS;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = vaddr;
  top->imm_i = 0;
  top->rob_tag_i = 0x26;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "MMU load pf: req accepted");
  tick(top);
  top->req_valid_i = 0;

  wait_pte_req(top, l1_addr, "MMU load pf: L1 pte address");
  feed_pte_rsp(top, l1_ptr_pte);
  wait_pte_req(top, l0_addr, "MMU load pf: L0 pte address");
  feed_pte_rsp(top, l0_leaf_xonly);

  for (int i = 0; i < 20; i++) {
    eval_comb(top);
    if (top->wb_valid_o) {
      expect(top->wb_exception_o == 1, "MMU load pf: wb exception");
      expect(top->wb_ecause_o == 13, "MMU load pf: ecause=13");
      expect(top->wb_data_o == vaddr, "MMU load pf: wb_data carries faulting vaddr");
      expect(top->ld_req_valid_o == 0, "MMU load pf: no dcache load req");
      tick(top);
      return;
    }
    tick(top);
  }
  expect(false, "MMU load pf: timeout waiting wb");
}

static void test_mmu_store_page_fault(Vtb_lsu *top) {
  set_defaults(top);
  const uint32_t vaddr = 0x80404000u;
  const uint32_t l0_table_pa = 0x00102000u;
  const uint32_t root_pa = satp_root_pa(kSatpSv32Root);
  const uint32_t l1_addr = root_pa + vpn1(vaddr) * 4u;
  const uint32_t l0_addr = l0_table_pa + vpn0(vaddr) * 4u;
  const uint32_t l1_ptr_pte = ((l0_table_pa >> 12) << 10) | kPteV;
  const uint32_t l0_leaf_ro = make_leaf_pte(0x80004000u, kPteR | kPteA | kPteD);
  bool saw_sb_ex = false;

  top->mmu_satp_i = kSatpSv32Root;
  top->mmu_priv_i = kPrivS;
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = vaddr;
  top->imm_i = 0;
  top->rs2_data_i = 0x44556677;
  top->rob_tag_i = 0x27;
  top->st_id_i = 0x2;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "MMU store pf: req accepted");
  tick(top);
  top->req_valid_i = 0;

  wait_pte_req(top, l1_addr, "MMU store pf: L1 pte address");
  feed_pte_rsp(top, l1_ptr_pte);
  wait_pte_req(top, l0_addr, "MMU store pf: L0 pte address");
  feed_pte_rsp(top, l0_leaf_ro);

  for (int i = 0; i < 20; i++) {
    eval_comb(top);
    if (top->st_ex_valid_o) saw_sb_ex = true;
    if (top->wb_valid_o) {
      expect(!saw_sb_ex, "MMU store pf: no store-buffer enqueue");
      expect(top->wb_exception_o == 1, "MMU store pf: wb exception");
      expect(top->wb_ecause_o == 15, "MMU store pf: ecause=15");
      expect(top->wb_data_o == vaddr, "MMU store pf: wb_data carries faulting vaddr");
      tick(top);
      return;
    }
    tick(top);
  }
  expect(false, "MMU store pf: timeout waiting wb");
}

static void test_mmu_sfence_flush_forces_walk(Vtb_lsu *top) {
  set_defaults(top);
  const uint32_t vaddr = 0x80405000u;
  const uint32_t l0_table_pa = 0x00102000u;
  const uint32_t root_pa = satp_root_pa(kSatpSv32Root);
  const uint32_t l1_addr = root_pa + vpn1(vaddr) * 4u;
  const uint32_t l0_addr = l0_table_pa + vpn0(vaddr) * 4u;
  const uint32_t l1_ptr_pte = ((l0_table_pa >> 12) << 10) | kPteV;
  const uint32_t l0_leaf_rw = make_leaf_pte(0x80005000u, kPteR | kPteW | kPteA | kPteD);

  auto run_load_once = [&](bool expect_walk) {
    top->is_load_i = 1;
    top->is_store_i = 0;
    top->lsu_op_i = LSU_LW;
    top->rs1_data_i = vaddr;
    top->imm_i = 0;
    top->rob_tag_i = 0x28;
    top->req_valid_i = 1;
    eval_comb(top);
    expect(top->req_ready_o == 1, "MMU sfence: req accepted");
    tick(top);
    top->req_valid_i = 0;

    if (expect_walk) {
      wait_pte_req(top, l1_addr, "MMU sfence: L1 after miss/flush");
      feed_pte_rsp(top, l1_ptr_pte);
      wait_pte_req(top, l0_addr, "MMU sfence: L0 after miss/flush");
      feed_pte_rsp(top, l0_leaf_rw);
    } else {
      for (int i = 0; i < 4; i++) {
        eval_comb(top);
        expect(top->pte_req_valid_o == 0, "MMU sfence: tlb hit should skip walk");
        tick(top);
      }
    }

    top->ld_req_ready_i = 1;
    for (int i = 0; i < 10; i++) {
      eval_comb(top);
      if (top->ld_req_valid_o) {
        tick(top);
        break;
      }
      tick(top);
    }
    top->ld_req_ready_i = 0;
    top->ld_rsp_valid_i = 1;
    top->ld_rsp_id_i = 0;
    top->ld_rsp_data_i = 0x99887766;
    top->ld_rsp_err_i = 0;
    tick(top);
    top->ld_rsp_valid_i = 0;
    eval_comb(top);
    if (top->wb_valid_o) tick(top);
  };

  top->mmu_satp_i = kSatpSv32Root;
  top->mmu_priv_i = kPrivS;
  run_load_once(true);
  run_load_once(false);
  top->mmu_sfence_vma_i = 1;
  tick(top);
  top->mmu_sfence_vma_i = 0;
  run_load_once(true);
}

static void test_group_accepts_second_req_when_first_waits_dcache(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x5000);
  top->imm_i = 0;
  top->rob_tag_i = 0xC;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group: first load accepted");

  tick(top); // lane0 -> S_LD_REQ

  // Keep lane0 waiting for D$ request grant, then issue second load.
  top->ld_req_ready_i = 0;
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x6000);
  top->imm_i = 4;
  top->rob_tag_i = 0xD;

  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group: second load accepted on free lane");
  expect(top->ld_req_valid_o == 1, "LSU group: D$ request stays valid for first load");
  expect(top->ld_req_addr_o == pmem_addr(0x5000), "LSU group: D$ request address remains first load");

  tick(top); // lane1 -> S_LD_REQ

  // Both lanes are busy now, so a third request must be blocked.
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x7000);
  top->imm_i = 8;
  top->rob_tag_i = 0xE;
  eval_comb(top);
  expect(top->req_ready_o == 0, "LSU group: third load blocked when both lanes busy");

  // Complete first request then second request so testcase can exit cleanly.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  tick(top); // lane0 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0xCAFEBABE;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group: first load eventually writebacks");
  expect(top->wb_rob_idx_o == 0xC, "LSU group: first writeback tag belongs to first load");
  tick(top); // lane0 response/writeback consumed
  top->ld_rsp_valid_i = 0;

  top->ld_req_ready_i = 1;
  tick(top); // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x1234ABCD;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group: second load eventually writebacks");
  expect(top->wb_rob_idx_o == 0xD, "LSU group: second writeback tag belongs to second load");
  tick(top); // lane1 response/writeback consumed
  top->ld_rsp_valid_i = 0;
}

static void test_group_allows_store_when_load_lanes_wait_dcache(Vtb_lsu *top) {
  set_defaults(top);

  // Fill lane0 with a load that cannot issue dcache req yet.
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x5200);
  top->imm_i = 0;
  top->rob_tag_i = 0x1A;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ls/st decouple: first load accepted");
  tick(top);  // lane0 -> S_LD_REQ

  // Fill lane1 with another load that also waits on dcache req.
  top->ld_req_ready_i = 0;
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x5300);
  top->imm_i = 0;
  top->rob_tag_i = 0x1B;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ls/st decouple: second load accepted");
  tick(top);  // lane1 -> S_LD_REQ

  // While both load lanes wait for dcache ownership, a store should still be accepted.
  top->req_valid_i = 1;
  top->is_load_i = 0;
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x5400;
  top->imm_i = 8;
  top->rs2_data_i = 0xA1B2C3D4;
  top->rob_tag_i = 0x1C;
  top->st_id_i = 0x6;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ls/st decouple: store accepted while loads wait dcache");
  expect(top->st_ex_valid_o == 1, "LSU ls/st decouple: store writes STQ without waiting load lane");
  expect(top->st_ex_addr_o == 0x5408, "LSU ls/st decouple: store address");
  expect(top->st_ex_data_o == 0xA1B2C3D4, "LSU ls/st decouple: store data");
  tick(top);

  // Let store and both loads drain for clean test exit.
  top->req_valid_i = 0;
  top->wb_ready_i = 1;
  eval_comb(top);
  if (top->wb_valid_o) tick(top);  // store wb if present

  top->ld_req_ready_i = 1;
  tick(top);  // one lane issues req
  tick(top);  // another lane issues req
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x11112222;
  top->ld_rsp_err_i = 0;
  tick(top);
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x33334444;
  tick(top);
  top->ld_rsp_valid_i = 0;
}

static void test_store_can_complete_without_dcache_roundtrip(Vtb_lsu *top) {
  set_defaults(top);
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x7000;
  top->imm_i = 8;
  top->rs2_data_i = 0x11223344;
  top->rob_tag_i = 0xF;
  top->st_id_i = 0x3;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Store no dcache roundtrip: req_ready");
  expect(top->st_ex_valid_o == 1, "Store no dcache roundtrip: st_ex_valid");
  expect(top->ld_req_valid_o == 0, "Store no dcache roundtrip: no ld_req on accept cycle");

  tick(top); // S_RESP
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Store no dcache roundtrip: wb_valid in next cycle");
  expect(top->wb_exception_o == 0, "Store no dcache roundtrip: no exception");
  expect(top->wb_rob_idx_o == 0xF, "Store no dcache roundtrip: wb tag");
  expect(top->ld_req_valid_o == 0, "Store no dcache roundtrip: still no ld_req");
  tick(top);
}

static void test_group_allows_new_req_when_older_lane_waits(Vtb_lsu *top) {
  set_defaults(top);

  // 1) First load -> lane0 (hold D$ req not ready)
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x8000);
  top->imm_i = 0;
  top->rob_tag_i = 0x10;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group order: first load accepted");
  tick(top);

  // 2) Second load -> lane1 (still block D$ req)
  top->ld_req_ready_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x8100);
  top->imm_i = 0;
  top->rob_tag_i = 0x11;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group order: second load accepted on lane1");
  tick(top);

  // 3) Let lane0 complete first, keep lane1 pending in S_LD_REQ
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  tick(top);  // lane0 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x11112222;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: first load writeback");
  expect(top->wb_rob_idx_o == 0x10, "LSU group order: first wb tag");
  tick(top);  // lane0 response/writeback consumed
  top->ld_rsp_valid_i = 0;

  // 4) While lane1 (older) waits for D$, lane0 can still accept newer request.
  top->ld_req_ready_i = 0; // keep D$ unavailable so lane1 remains pending
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x8200);
  top->imm_i = 0;
  top->rob_tag_i = 0x12;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group order: allow newer req when another lane waits");
  tick(top);  // lane0 accepts newer request
  top->req_valid_i = 0;

  // 5) Drain lane0/lane1 requests to reach response state.
  top->ld_req_ready_i = 1;
  tick(top);  // lane0 -> S_LD_RSP
  tick(top);  // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  // 6) Return lane1 first.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x33334444;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: older pending load writeback");
  expect(top->wb_rob_idx_o == 0x11, "LSU group order: older pending load wb tag");
  tick(top);  // lane1 response/writeback consumed
  top->ld_rsp_valid_i = 0;

  // 7) Return newer lane0 load.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x55556666;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: newer load writeback");
  expect(top->wb_rob_idx_o == 0x12, "LSU group order: newer load wb tag");
  tick(top);  // lane0 response/writeback consumed
  top->ld_rsp_valid_i = 0;
}

static void test_group_allows_req_on_rsp_handoff_cycle(Vtb_lsu *top) {
  set_defaults(top);

  // 1) First load -> lane0
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x9000);
  top->imm_i = 0;
  top->rob_tag_i = 0x13;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU handoff: first load accepted");
  tick(top); // lane0 -> S_LD_REQ

  // 2) Second load -> lane1 while lane0 waits for D$ req
  top->ld_req_ready_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x9100);
  top->imm_i = 4;
  top->rob_tag_i = 0x14;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU handoff: second load accepted");
  tick(top); // lane1 -> S_LD_REQ

  // 3) Grant D$ request for lane0 so owner is established.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU handoff: lane0 request issues");
  expect(top->ld_req_addr_o == pmem_addr(0x9000), "LSU handoff: lane0 request addr");
  tick(top); // lane0 -> S_LD_RSP, owner=lane0

  // 4) In rsp-fire cycle, lane1 is still waiting req.
  // Expected: lane1 request can be issued without one-cycle bubble.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0xAAAA5555;
  top->ld_rsp_err_i = 0;
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU handoff: lane0 response ready");
  expect(top->ld_req_valid_o == 1, "LSU handoff: lane1 request should issue on rsp-fire cycle");
  expect(top->ld_req_addr_o == pmem_addr(0x9104), "LSU handoff: lane1 request addr on rsp-fire cycle");
  expect(top->ld_req_id_o == 1, "LSU handoff: lane1 request id on rsp-fire cycle");
  expect(top->wb_valid_o == 1, "LSU handoff: lane0 writeback on rsp cycle");
  expect(top->wb_rob_idx_o == 0x13, "LSU handoff: lane0 wb tag on rsp cycle");
  tick(top); // lane0 rsp consumed, lane1 request should handshake

  // 5) lane0 already wrote back on rsp cycle.
  top->ld_rsp_valid_i = 0;

  // 6) Complete lane1 response/writeback to exit cleanly.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x12345678;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU handoff: lane1 response ready");
  expect(top->wb_valid_o == 1, "LSU handoff: lane1 writeback");
  expect(top->wb_rob_idx_o == 0x14, "LSU handoff: lane1 wb tag");
  tick(top);  // lane1 response/writeback consumed
  top->ld_rsp_valid_i = 0;
}

static void test_group_writes_back_on_load_rsp_cycle(Vtb_lsu *top) {
  set_defaults(top);

  // 1) Issue one load.
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0x9300);
  top->imm_i = 0;
  top->rob_tag_i = 0x17;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU rsp->wb: load accepted");
  tick(top);  // lane -> S_LD_REQ
  top->req_valid_i = 0;

  // 2) Fire D$ request.
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU rsp->wb: ld_req valid");
  tick(top);  // lane -> S_LD_RSP
  top->ld_req_ready_i = 0;

  // 3) Response cycle should already expose wb_valid (no extra S_RESP bubble).
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x13572468;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU rsp->wb: ld_rsp ready");
  expect(top->wb_valid_o == 1, "LSU rsp->wb: wb valid on rsp cycle");
  expect(top->wb_rob_idx_o == 0x17, "LSU rsp->wb: wb tag on rsp cycle");
  expect(top->wb_data_o == 0x13572468, "LSU rsp->wb: wb data on rsp cycle");
  tick(top);

  top->ld_rsp_valid_i = 0;
}

static void test_group_accepts_req_on_wb_handoff_cycle(Vtb_lsu *top) {
  set_defaults(top);

  // Fill both lanes with stores and hold writeback so both remain in S_RESP.
  top->wb_ready_i = 0;

  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x9400;
  top->imm_i = 0;
  top->rs2_data_i = 0x11111111;
  top->rob_tag_i = 0x30;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU wb-handoff: first store accepted");
  tick(top);  // lane0 -> S_RESP

  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x9500;
  top->imm_i = 0;
  top->rs2_data_i = 0x22222222;
  top->rob_tag_i = 0x31;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU wb-handoff: second store accepted");
  tick(top);  // lane1 -> S_RESP

  // Both lanes are now in S_RESP and writeback is blocked.
  top->req_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU wb-handoff: writeback pending while blocked");

  // On writeback handoff cycle, group should both retire one wb and accept a new req.
  top->wb_ready_i = 1;
  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x9600;
  top->imm_i = 0;
  top->rs2_data_i = 0x33333333;
  top->rob_tag_i = 0x32;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU wb-handoff: wb valid on handoff cycle");
  expect(top->req_ready_o == 1, "LSU wb-handoff: new req accepted on wb handoff cycle");
  tick(top);

  // Drain remaining writebacks.
  top->req_valid_i = 0;
  for (int i = 0; i < 4; i++) {
    eval_comb(top);
    if (top->wb_valid_o == 0) break;
    tick(top);
  }
}

static void test_group_supports_two_outstanding_with_rsp_id(Vtb_lsu *top) {
  set_defaults(top);

  // 1) First load -> lane0
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0xA000);
  top->imm_i = 0;
  top->rob_tag_i = 0x20;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ooorsp: first load accepted");
  tick(top); // lane0 -> S_LD_REQ

  // 2) Second load -> lane1 while lane0 waits D$ req grant.
  top->ld_req_ready_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0xA100);
  top->imm_i = 4;
  top->rob_tag_i = 0x21;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ooorsp: second load accepted");
  tick(top); // lane1 -> S_LD_REQ

  // 3) Fire lane0 load request first.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU ooorsp: lane0 request valid");
  expect(top->ld_req_addr_o == pmem_addr(0xA000), "LSU ooorsp: lane0 request addr");
  expect(top->ld_req_id_o == 0, "LSU ooorsp: lane0 request id");
  tick(top); // lane0 -> S_LD_RSP

  // 4) Without waiting for lane0 response, lane1 request should also fire.
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU ooorsp: lane1 request valid before lane0 response");
  expect(top->ld_req_addr_o == pmem_addr(0xA104), "LSU ooorsp: lane1 request addr");
  expect(top->ld_req_id_o == 1, "LSU ooorsp: lane1 request id");
  tick(top); // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  // 5) Return lane1 response first (out-of-order by request issue order).
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x56781234;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU ooorsp: lane1 response ready");
  expect(top->wb_valid_o == 1, "LSU ooorsp: lane1 writeback first");
  expect(top->wb_rob_idx_o == 0x21, "LSU ooorsp: lane1 wb tag");
  expect(top->wb_data_o == 0x56781234, "LSU ooorsp: lane1 wb data");
  tick(top); // lane1 response/writeback consumed
  top->ld_rsp_valid_i = 0;

  // 6) Return lane0 response later.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x89ABCDEF;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU ooorsp: lane0 response ready");
  expect(top->wb_valid_o == 1, "LSU ooorsp: lane0 writeback second");
  expect(top->wb_rob_idx_o == 0x20, "LSU ooorsp: lane0 wb tag");
  expect(top->wb_data_o == 0x89ABCDEF, "LSU ooorsp: lane0 wb data");
  tick(top); // lane0 response/writeback consumed
  top->ld_rsp_valid_i = 0;
}

// NOTE: Store-to-load forwarding (incl. byte-merge / age ordering) moved out of
// lsu_group into stq (A3). tb_lsu instantiates lsu_group in isolation
// (no stq), so the former internal-forwarding "SQ fwd" tests were
// removed; that behavior is now covered end-to-end by difftest.

static void test_group_wb_round_robin_prevents_lane_starvation(Vtb_lsu *top) {
  set_defaults(top);

  // Block WB so lane0 cannot handoff-accept during seeding.
  top->wb_ready_i = 0;

  // Seed lane0 and lane1 with one store each.
  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0xC000;
  top->imm_i = 0;
  top->rs2_data_i = 0x11111111;
  top->rob_tag_i = 0x10;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU wb-rr: seed lane0 store accepted");
  tick(top);

  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0xC100;
  top->imm_i = 0;
  top->rs2_data_i = 0x22222222;
  top->rob_tag_i = 0x11;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU wb-rr: seed lane1 store accepted");
  tick(top);

  // Release WB and start continuous store stream.
  top->wb_ready_i = 1;
  bool saw_lane1_retire = false;
  uint32_t stream_tag = 0x20;

  // Keep injecting new stores; without fair WB arbitration lane0 can monopolize WB.
  for (int i = 0; i < 8; i++) {
    top->req_valid_i = 1;
    top->is_store_i = 1;
    top->is_load_i = 0;
    top->lsu_op_i = LSU_SW;
    top->rs1_data_i = 0xD000 + (i * 4);
    top->imm_i = 0;
    top->rs2_data_i = 0xABCD0000 + i;
    top->rob_tag_i = stream_tag++;

    eval_comb(top);
    expect(top->wb_valid_o == 1, "LSU wb-rr: wb must stay active under store stream");
    if (top->wb_rob_idx_o == 0x11) {
      saw_lane1_retire = true;
    }
    tick(top);
  }

  top->req_valid_i = 0;
  eval_comb(top);
  expect(saw_lane1_retire,
         "LSU wb-rr: lane1 seeded store must retire (no starvation under lane0 stream)");
}

static void test_group_ldreq_round_robin_prefers_waiting_lane(Vtb_lsu *top) {
  set_defaults(top);

  // 1) Seed lane0 with one load and let it fire once, so RR pointer can move.
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0xE000);
  top->imm_i = 0;
  top->rob_tag_i = 0x30;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ldreq-rr: seed lane0 load accepted");
  tick(top);
  top->req_valid_i = 0;

  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU ldreq-rr: seed lane0 issues to dcache");
  expect(top->ld_req_id_o == 0, "LSU ldreq-rr: seed id should be lane0");
  tick(top);
  top->ld_req_ready_i = 0;

  // 2) Queue one lane1 load while lane0 waits response.
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0xE100);
  top->imm_i = 0;
  top->rob_tag_i = 0x31;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ldreq-rr: lane1 load accepted");
  tick(top);
  top->req_valid_i = 0;

  // 3) Resolve lane0 response and handoff-accept a new lane0 load in same cycle.
  // Keep dcache req blocked so lane1 remains pending in LD_REQ.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0xAAAABBBB;
  top->ld_rsp_err_i = 0;

  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = pmem_addr(0xE200);
  top->imm_i = 0;
  top->rob_tag_i = 0x32;
  top->ld_req_ready_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU ldreq-rr: lane0 response writeback visible");
  expect(top->req_ready_o == 1, "LSU ldreq-rr: lane0 handoff accepts new load");
  tick(top);
  top->ld_rsp_valid_i = 0;
  top->req_valid_i = 0;

  // 4) Both lane0 and lane1 now have pending LD_REQ. RR should pick lane1 first.
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU ldreq-rr: request valid when both lanes pending");
  expect(top->ld_req_id_o == 1, "LSU ldreq-rr: waiting lane1 should win over lane0");
  expect(top->ld_req_addr_o == pmem_addr(0xE100), "LSU ldreq-rr: granted address should be lane1");
  tick(top);
  top->ld_req_ready_i = 0;
}

static void test_lq_queue_occupancy_four_entries(Vtb_lsu *top) {
  set_defaults(top);

  for (uint32_t i = 0; i < 4; i++) {
    top->lq_test_alloc_valid_i = 1;
    top->lq_test_alloc_rob_tag_i = 0x20 + i;
    eval_comb(top);
    expect(top->lq_test_alloc_ready_o == 1, "LQ queue: alloc ready for 4-entry fill");
    tick(top);
  }

  top->lq_test_alloc_valid_i = 0;
  eval_comb(top);
  expect(top->lq_test_count_o == 4, "LQ queue: occupancy reaches 4");
  expect(top->lq_test_head_valid_o == 1, "LQ queue: head valid after fill");
  expect(top->lq_test_head_rob_tag_o == 0x20, "LQ queue: lowest-index entry visible at head");

  // B2: entries are freed associatively by committing rob_idx (out-of-order
  // capable). Free them oldest-first and confirm the occupancy drains.
  for (uint32_t i = 0; i < 4; i++) {
    top->lq_test_commit_valid_i = 1;
    top->lq_test_commit_rob_idx_i = 0x20 + i;
    eval_comb(top);
    expect(top->lq_test_count_o == (4 - i), "LQ queue: occupancy before commit");
    tick(top);
  }
  top->lq_test_commit_valid_i = 0;

  eval_comb(top);
  expect(top->lq_test_count_o == 0, "LQ queue: occupancy returns to zero");
  expect(top->lq_test_head_valid_o == 0, "LQ queue: head invalid when empty");

  // Out-of-order free: refill, then commit a middle entry first.
  for (uint32_t i = 0; i < 4; i++) {
    top->lq_test_alloc_valid_i = 1;
    top->lq_test_alloc_rob_tag_i = 0x30 + i;
    eval_comb(top);
    tick(top);
  }
  top->lq_test_alloc_valid_i = 0;
  eval_comb(top);
  expect(top->lq_test_count_o == 4, "LQ queue: occupancy reaches 4 (refill)");

  top->lq_test_commit_valid_i = 1;
  top->lq_test_commit_rob_idx_i = 0x32;  // free a non-oldest entry
  eval_comb(top);
  tick(top);
  top->lq_test_commit_valid_i = 0;
  eval_comb(top);
  expect(top->lq_test_count_o == 3, "LQ queue: out-of-order commit frees one slot");

  // Committing a rob_idx with no matching entry must be a no-op.
  top->lq_test_commit_valid_i = 1;
  top->lq_test_commit_rob_idx_i = 0x3F;
  eval_comb(top);
  tick(top);
  top->lq_test_commit_valid_i = 0;
  eval_comb(top);
  expect(top->lq_test_count_o == 3, "LQ queue: non-matching commit is a no-op");
}

static uint32_t amo_expected(uint32_t op, uint32_t old_val, uint32_t operand) {
  switch (op) {
  case AMO_SWAP:
    return operand;
  case AMO_ADD:
    return old_val + operand;
  case AMO_XOR:
    return old_val ^ operand;
  case AMO_AND:
    return old_val & operand;
  case AMO_OR:
    return old_val | operand;
  case AMO_MIN:
    return (static_cast<int32_t>(old_val) < static_cast<int32_t>(operand)) ? old_val
                                                                           : operand;
  case AMO_MAX:
    return (static_cast<int32_t>(old_val) > static_cast<int32_t>(operand)) ? old_val
                                                                           : operand;
  case AMO_MINU:
    return (old_val < operand) ? old_val : operand;
  case AMO_MAXU:
    return (old_val > operand) ? old_val : operand;
  default:
    return old_val;
  }
}

static void run_amo_forward_case(Vtb_lsu *top, uint32_t amo_op, uint32_t old_val,
                                 uint32_t operand, const char *msg) {
  set_defaults(top);

  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 1;
  top->lsu_op_i = LSU_AMO;
  top->amo_op_i = amo_op;
  top->rs1_data_i = pmem_addr(0xF000);
  top->imm_i = 0;
  top->rs2_data_i = operand;
  top->rob_tag_i = 0x2A;
  top->st_id_i = 0x4;
  top->stq_fwd_hit_i = 1;
  top->stq_fwd_data_i = old_val;

  eval_comb(top);
  expect(top->req_ready_o == 1, msg);
  expect(top->stq_fwd_addr_o == pmem_addr(0xF000), "AMO fwd: queries forwarding at AMO address");
  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "AMO fwd: writeback valid");
  expect(top->wb_rob_idx_o == 0x2A, "AMO fwd: writeback tag");
  expect(top->wb_data_o == old_val, "AMO fwd: writeback returns old value");
  expect(top->st_ex_valid_o == 1, "AMO fwd: store buffer write valid");
  expect(top->st_ex_st_id_o == 0x4, "AMO fwd: store buffer id");
  expect(top->st_ex_op_o == LSU_SW, "AMO fwd: store buffer op is SW");
  expect(top->st_ex_data_o == amo_expected(amo_op, old_val, operand),
         "AMO fwd: store buffer receives computed new value");
  tick(top);
}

static void test_amo_forward_all_ops(Vtb_lsu *top) {
  run_amo_forward_case(top, AMO_SWAP, 0x80000001u, 0x00000005u, "AMOSWAP fwd: accepted");
  run_amo_forward_case(top, AMO_ADD, 0x00000010u, 0x00000005u, "AMOADD fwd: accepted");
  run_amo_forward_case(top, AMO_XOR, 0x00FF00FFu, 0x0F0F0000u, "AMOXOR fwd: accepted");
  run_amo_forward_case(top, AMO_AND, 0x00FF00FFu, 0x0F0F0000u, "AMOAND fwd: accepted");
  run_amo_forward_case(top, AMO_OR, 0x00FF00FFu, 0x0F0F0000u, "AMOOR fwd: accepted");
  run_amo_forward_case(top, AMO_MIN, 0x80000000u, 0x00000001u, "AMOMIN fwd: accepted");
  run_amo_forward_case(top, AMO_MAX, 0x80000000u, 0x00000001u, "AMOMAX fwd: accepted");
  run_amo_forward_case(top, AMO_MINU, 0x80000000u, 0x00000001u, "AMOMINU fwd: accepted");
  run_amo_forward_case(top, AMO_MAXU, 0x80000000u, 0x00000001u, "AMOMAXU fwd: accepted");
}

static void test_amo_dcache_rmw_path(Vtb_lsu *top) {
  set_defaults(top);

  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 1;
  top->lsu_op_i = LSU_AMO;
  top->amo_op_i = AMO_ADD;
  top->rs1_data_i = pmem_addr(0xF100);
  top->imm_i = 4;
  top->rs2_data_i = 0x00000007;
  top->rob_tag_i = 0x2B;
  top->st_id_i = 0x5;

  eval_comb(top);
  expect(top->req_ready_o == 1, "AMO dcache: accepted");
  tick(top);
  top->req_valid_i = 0;

  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "AMO dcache: load request valid");
  expect(top->ld_req_addr_o == pmem_addr(0xF104), "AMO dcache: load request addr");
  expect(top->ld_req_op_o == LSU_AMO, "AMO dcache: load op tags AMO");
  tick(top);
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x00000020;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "AMO dcache: writeback valid on response");
  expect(top->wb_rob_idx_o == 0x2B, "AMO dcache: writeback tag");
  expect(top->wb_data_o == 0x00000020, "AMO dcache: writeback old value");
  expect(top->st_ex_valid_o == 1, "AMO dcache: store buffer write valid");
  expect(top->st_ex_addr_o == pmem_addr(0xF104), "AMO dcache: store address");
  expect(top->st_ex_data_o == 0x00000027, "AMO dcache: store new value");
  expect(top->st_ex_op_o == LSU_SW, "AMO dcache: store op is SW");
  tick(top);
  top->ld_rsp_valid_i = 0;
}

static void test_amo_misaligned_reports_store_exception(Vtb_lsu *top) {
  set_defaults(top);

  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 1;
  top->lsu_op_i = LSU_AMO;
  top->amo_op_i = AMO_ADD;
  top->rs1_data_i = pmem_addr(0xF200);
  top->imm_i = 2;
  top->rs2_data_i = 1;
  top->rob_tag_i = 0x2C;

  eval_comb(top);
  expect(top->req_ready_o == 1, "AMO misaligned: accepted");
  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "AMO misaligned: writeback valid");
  expect(top->wb_exception_o == 1, "AMO misaligned: exception");
  expect(top->wb_ecause_o == 6, "AMO misaligned: store/AMO address misaligned");
  expect(top->st_ex_valid_o == 0, "AMO misaligned: no store buffer write");
  tick(top);
}

static void test_amo_blocks_younger_lsu_until_rmw_finishes(Vtb_lsu *top) {
  set_defaults(top);

  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 1;
  top->lsu_op_i = LSU_AMO;
  top->amo_op_i = AMO_OR;
  top->rs1_data_i = pmem_addr(0xF300);
  top->imm_i = 0;
  top->rs2_data_i = 0x10;
  top->rob_tag_i = 0x2D;
  top->st_id_i = 0x6;
  eval_comb(top);
  expect(top->req_ready_o == 1, "AMO ordering: AMO accepted");
  tick(top);

  top->is_store_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->amo_op_i = AMO_NONE;
  top->rs1_data_i = pmem_addr(0xF304);
  top->rob_tag_i = 0x2E;
  eval_comb(top);
  expect(top->req_ready_o == 0, "AMO ordering: younger LSU blocked while AMO waits");

  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  tick(top);
  top->ld_req_ready_i = 0;
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x20;
  top->ld_rsp_err_i = 0;
  tick(top);
  top->ld_rsp_valid_i = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_lsu *top = new Vtb_lsu;

  reset(top);

  std::cout << "Running LSU unit tests..." << std::endl;

  test_store_aligned(top);
  test_store_misaligned(top);
  test_load_forward_lb(top);
  test_load_dcache_ok(top);
  test_load_misaligned(top);
  test_load_access_fault(top);
  test_mmu_load_page_fault(top);
  test_mmu_store_page_fault(top);
  test_mmu_sfence_flush_forces_walk(top);
  test_group_accepts_second_req_when_first_waits_dcache(top);
  test_group_allows_store_when_load_lanes_wait_dcache(top);
  test_store_can_complete_without_dcache_roundtrip(top);
  test_group_allows_new_req_when_older_lane_waits(top);
  test_group_allows_req_on_rsp_handoff_cycle(top);
  test_group_writes_back_on_load_rsp_cycle(top);
  test_group_accepts_req_on_wb_handoff_cycle(top);
  test_group_supports_two_outstanding_with_rsp_id(top);
  test_group_wb_round_robin_prevents_lane_starvation(top);
  test_group_ldreq_round_robin_prefers_waiting_lane(top);
  test_lq_queue_occupancy_four_entries(top);
  test_amo_forward_all_ops(top);
  test_amo_dcache_rmw_path(top);
  test_amo_misaligned_reports_store_exception(top);
  test_amo_blocks_younger_lsu_until_rmw_finishes(top);

  std::cout << ANSI_RES_GRN << "--- [ALL LSU TESTS PASSED] ---" << ANSI_RES_RST << std::endl;

  delete top;
  return 0;
}
