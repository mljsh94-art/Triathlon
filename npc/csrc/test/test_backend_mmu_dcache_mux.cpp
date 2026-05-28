#include "Vtb_backend_mmu_dcache_mux.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>

#define ANSI_RES_GRN "\x1b[32m"
#define ANSI_RES_RED "\x1b[31m"
#define ANSI_RES_RST "\x1b[0m"

namespace {
constexpr uint32_t LSU_LWU = 6;
constexpr uint32_t LSU_SW = 9;
constexpr uint32_t MMU_RSP_ID = 4;

void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cout << "[ " << ANSI_RES_RED << "FAIL" << ANSI_RES_RST << " ] " << msg << "\n";
    std::exit(1);
  }
  std::cout << "[ " << ANSI_RES_GRN << "PASS" << ANSI_RES_RST << " ] " << msg << "\n";
}

void clear_inputs(Vtb_backend_mmu_dcache_mux *top) {
  top->flush_i = 0;
  top->lsu_ld_req_valid_i = 0;
  top->lsu_ld_req_addr_i = 0;
  top->lsu_ld_req_op_i = 0;
  top->lsu_ld_req_id_i = 0;
  top->lsu_ld_rsp_ready_i = 0;

  top->pte_ld_req_valid_i = 0;
  top->pte_ld_req_paddr_i = 0;
  top->ifu_pte_ld_req_valid_i = 0;
  top->ifu_pte_ld_req_paddr_i = 0;

  top->sb_st_req_valid_i = 0;
  top->sb_st_req_addr_i = 0;
  top->sb_st_req_data_i = 0;
  top->sb_st_req_op_i = 0;

  top->pte_st_req_valid_i = 0;
  top->pte_st_req_paddr_i = 0;
  top->pte_st_req_data_i = 0;
  top->ifu_pte_st_req_valid_i = 0;
  top->ifu_pte_st_req_paddr_i = 0;
  top->ifu_pte_st_req_data_i = 0;

  top->dcache_ld_req_ready_i = 0;
  top->dcache_ld_rsp_valid_i = 0;
  top->dcache_ld_rsp_data_i = 0;
  top->dcache_ld_rsp_err_i = 0;
  top->dcache_ld_rsp_id_i = 0;

  top->dcache_st_req_ready_i = 0;
}

void eval_comb(Vtb_backend_mmu_dcache_mux *top) {
  top->clk_i = 0;
  top->eval();
}

void tick(Vtb_backend_mmu_dcache_mux *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

void reset(Vtb_backend_mmu_dcache_mux *top) {
  top->rst_ni = 0;
  clear_inputs(top);
  tick(top);
  tick(top);
  top->rst_ni = 1;
  tick(top);
}

void test_lsu_pte_load_priority(Vtb_backend_mmu_dcache_mux *top) {
  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->lsu_ld_req_valid_i = 1;
  top->lsu_ld_req_addr_i = 0x80001000u;
  top->lsu_ld_req_op_i = 2;
  top->lsu_ld_req_id_i = 2;
  top->pte_ld_req_valid_i = 1;
  top->pte_ld_req_paddr_i = 0x00102004u;
  top->ifu_pte_ld_req_valid_i = 1;
  top->ifu_pte_ld_req_paddr_i = 0x00105000u;
  eval_comb(top);

  expect(top->dcache_ld_req_valid_o == 1, "pte load priority: dcache ld req valid");
  expect(top->dcache_ld_req_addr_o == 0x00102004u, "pte load priority: addr selects lsu pte");
  expect(top->dcache_ld_req_op_o == LSU_LWU, "pte load priority: op is LSU_LWU");
  expect(top->dcache_ld_req_id_o == MMU_RSP_ID, "pte load priority: id uses mmu src bit");
  expect(top->pte_ld_req_ready_o == 1, "pte load priority: lsu pte ready asserted");
  expect(top->ifu_pte_ld_req_ready_o == 0, "pte load priority: ifu pte blocked");
  expect(top->lsu_ld_req_ready_o == 0, "pte load priority: lsu not selected");
}

void test_lsu_load_path_and_rsp_route(Vtb_backend_mmu_dcache_mux *top) {
  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->lsu_ld_req_valid_i = 1;
  top->lsu_ld_req_addr_i = 0x80004000u;
  top->lsu_ld_req_op_i = 2;
  top->lsu_ld_req_id_i = 3;
  eval_comb(top);

  expect(top->dcache_ld_req_valid_o == 1, "lsu load path: dcache ld req valid");
  expect(top->dcache_ld_req_addr_o == 0x80004000u, "lsu load path: addr selects lsu");
  expect(top->dcache_ld_req_id_o == 3, "lsu load path: id keeps lsu id");
  expect(top->lsu_ld_req_ready_o == 1, "lsu load path: lsu ready asserted");
  expect(top->pte_ld_req_ready_o == 0, "lsu load path: pte ready deasserted");

  clear_inputs(top);
  top->lsu_ld_rsp_ready_i = 0;
  top->dcache_ld_rsp_valid_i = 1;
  top->dcache_ld_rsp_data_i = 0xDEADBEEFu;
  top->dcache_ld_rsp_err_i = 1;
  top->dcache_ld_rsp_id_i = 3;
  eval_comb(top);
  expect(top->lsu_ld_rsp_valid_o == 1, "rsp route: lsu rsp valid");
  expect(top->lsu_ld_rsp_data_o == 0xDEADBEEFu, "rsp route: lsu rsp data");
  expect(top->lsu_ld_rsp_err_o == 1, "rsp route: lsu rsp err");
  expect(top->lsu_ld_rsp_id_o == 3, "rsp route: lsu rsp id");
  expect(top->dcache_ld_rsp_ready_o == 0, "rsp route: lsu backpressure propagates");

  top->lsu_ld_rsp_ready_i = 1;
  eval_comb(top);
  expect(top->dcache_ld_rsp_ready_o == 1, "rsp route: lsu ready propagates");

  clear_inputs(top);
  top->dcache_ld_rsp_valid_i = 1;
  top->dcache_ld_rsp_data_i = 0xCAFEBABEu;
  top->dcache_ld_rsp_id_i = MMU_RSP_ID;
  eval_comb(top);
  expect(top->pte_ld_rsp_valid_o == 1, "rsp route: pte rsp valid");
  expect(top->pte_ld_rsp_data_o == 0xCAFEBABEu, "rsp route: pte rsp data");
  expect(top->lsu_ld_rsp_valid_o == 0, "rsp route: pte rsp not sent to lsu");
  expect(top->dcache_ld_rsp_ready_o == 1, "rsp route: pte response always accepted");
}

void test_pte_store_priority(Vtb_backend_mmu_dcache_mux *top) {
  clear_inputs(top);
  top->dcache_st_req_ready_i = 1;
  top->sb_st_req_valid_i = 1;
  top->sb_st_req_addr_i = 0x80008000u;
  top->sb_st_req_data_i = 0x11112222u;
  top->sb_st_req_op_i = LSU_SW;
  top->pte_st_req_valid_i = 1;
  top->pte_st_req_paddr_i = 0x00103008u;
  top->pte_st_req_data_i = 0xA5A5C3C3u;
  top->ifu_pte_st_req_valid_i = 1;
  top->ifu_pte_st_req_paddr_i = 0x00105008u;
  top->ifu_pte_st_req_data_i = 0xB6B6D4D4u;
  eval_comb(top);

  expect(top->dcache_st_req_valid_o == 1, "pte store priority: dcache st req valid");
  expect(top->dcache_st_req_addr_o == 0x00103008u, "pte store priority: addr selects lsu pte");
  expect(top->dcache_st_req_data_o == 0xA5A5C3C3u, "pte store priority: data selects lsu pte");
  expect(top->dcache_st_req_op_o == LSU_SW, "pte store priority: op is LSU_SW");
  expect(top->pte_st_req_ready_o == 1, "pte store priority: lsu pte ready asserted");
  expect(top->ifu_pte_st_req_ready_o == 0, "pte store priority: ifu pte blocked");
  expect(top->sb_st_req_ready_o == 0, "pte store priority: sb not selected");
}

void test_ifu_pte_load_path_and_rsp_route(Vtb_backend_mmu_dcache_mux *top) {
  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->ifu_pte_ld_req_valid_i = 1;
  top->ifu_pte_ld_req_paddr_i = 0x00107004u;
  eval_comb(top);
  expect(top->dcache_ld_req_valid_o == 1, "ifu pte load: dcache ld req valid");
  expect(top->dcache_ld_req_addr_o == 0x00107004u, "ifu pte load: addr selects ifu pte");
  expect(top->dcache_ld_req_op_o == LSU_LWU, "ifu pte load: op is LSU_LWU");
  expect(top->dcache_ld_req_id_o == MMU_RSP_ID, "ifu pte load: id uses mmu src bit");
  expect(top->ifu_pte_ld_req_ready_o == 1, "ifu pte load: ifu pte ready asserted");
  expect(top->pte_ld_req_ready_o == 0, "ifu pte load: lsu pte blocked");
  tick(top);  // Latch MMU inflight owner

  clear_inputs(top);
  top->dcache_ld_rsp_valid_i = 1;
  top->dcache_ld_rsp_data_i = 0x44556677u;
  top->dcache_ld_rsp_id_i = MMU_RSP_ID;
  eval_comb(top);
  expect(top->ifu_pte_ld_rsp_valid_o == 1, "ifu pte rsp route: ifu rsp valid");
  expect(top->ifu_pte_ld_rsp_data_o == 0x44556677u, "ifu pte rsp route: ifu rsp data");
  expect(top->pte_ld_rsp_valid_o == 0, "ifu pte rsp route: not routed to lsu pte");
}

void test_single_outstanding_mmu_load(Vtb_backend_mmu_dcache_mux *top) {
  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->pte_ld_req_valid_i = 1;
  top->pte_ld_req_paddr_i = 0x00101000u;
  eval_comb(top);
  expect(top->pte_ld_req_ready_o == 1, "single outstanding: first mmu req accepted");
  tick(top);

  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->ifu_pte_ld_req_valid_i = 1;
  top->ifu_pte_ld_req_paddr_i = 0x00102000u;
  eval_comb(top);
  expect(top->dcache_ld_req_valid_o == 0, "single outstanding: second mmu req blocked");
  expect(top->ifu_pte_ld_req_ready_o == 0, "single outstanding: ifu req not ready while inflight");

  top->dcache_ld_rsp_valid_i = 1;
  top->dcache_ld_rsp_id_i = MMU_RSP_ID;
  top->dcache_ld_rsp_data_i = 0x12345678u;
  eval_comb(top);
  expect(top->pte_ld_rsp_valid_o == 1, "single outstanding: lsu mmu response drains inflight");
  tick(top);

  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->ifu_pte_ld_req_valid_i = 1;
  top->ifu_pte_ld_req_paddr_i = 0x00102000u;
  eval_comb(top);
  expect(top->ifu_pte_ld_req_ready_o == 1, "single outstanding: next mmu req accepted after drain");
}

void test_flush_clears_mmu_inflight(Vtb_backend_mmu_dcache_mux *top) {
  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->ifu_pte_ld_req_valid_i = 1;
  top->ifu_pte_ld_req_paddr_i = 0x00100000u;
  eval_comb(top);
  expect(top->ifu_pte_ld_req_ready_o == 1, "flush clear: initial ifu mmu req accepted");
  tick(top);  // Latch inflight as IFU owner.

  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->pte_ld_req_valid_i = 1;
  top->pte_ld_req_paddr_i = 0x00101000u;
  eval_comb(top);
  expect(top->pte_ld_req_ready_o == 0, "flush clear: lsu mmu req blocked by inflight");

  // Simulate backend flush (mispredict/trap) before dcache response returns.
  top->flush_i = 1;
  tick(top);

  clear_inputs(top);
  top->dcache_ld_req_ready_i = 1;
  top->pte_ld_req_valid_i = 1;
  top->pte_ld_req_paddr_i = 0x00101000u;
  eval_comb(top);
  expect(top->pte_ld_req_ready_o == 1, "flush clear: lsu mmu req accepted after flush");
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_backend_mmu_dcache_mux;
  reset(top);
  test_lsu_pte_load_priority(top);
  reset(top);
  test_lsu_load_path_and_rsp_route(top);
  reset(top);
  test_ifu_pte_load_path_and_rsp_route(top);
  reset(top);
  test_single_outstanding_mmu_load(top);
  reset(top);
  test_flush_clears_mmu_inflight(top);
  reset(top);
  test_pte_store_priority(top);

  std::cout << "--- ALL TESTS PASSED ---\n";
  delete top;
  return 0;
}
