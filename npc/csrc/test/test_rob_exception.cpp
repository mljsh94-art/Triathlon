#include "Vtb_rob_exception.h"
#include "verilated.h"

#include <cstdlib>
#include <iostream>

#define ANSI_RES_GRN "\x1b[32m"
#define ANSI_RES_RED "\x1b[31m"
#define ANSI_RES_RST "\x1b[0m"

namespace {

constexpr uint32_t kFuLsu = 3;
constexpr uint32_t kPageFault = 13;
constexpr uint32_t kFaultPc = 0xC00999F6u;
constexpr uint32_t kFaultTval = 0x82001F48u;
constexpr uint32_t kTrapVector = 0x80400100u;

void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cout << "[ " << ANSI_RES_RED << "FAIL" << ANSI_RES_RST << " ] " << msg << "\n";
    std::exit(1);
  }
  std::cout << "[ " << ANSI_RES_GRN << "PASS" << ANSI_RES_RST << " ] " << msg << "\n";
}

void clear_inputs(Vtb_rob_exception *top) {
  top->flush_i = 0;

  top->dispatch_valid_i = 0;
  top->dispatch_pc_i = 0;
  top->dispatch_fu_type_i = 0;
  top->dispatch_areg_i = 0;
  top->dispatch_has_rd_i = 0;
  top->dispatch_is_store_i = 0;
  top->dispatch_sb_id_i = 0;

  top->wb_valid_i = 0;
  top->wb_rob_index_i = 0;
  top->wb_data_i = 0;
  top->wb_exception_i = 0;
  top->wb_ecause_i = 0;
  top->wb_is_mispred_i = 0;
  top->wb_redirect_pc_i = 0;

  top->async_exception_valid_i = 0;
  top->async_exception_cause_i = 0;
  top->async_exception_pc_i = 0;
  top->async_exception_redirect_pc_i = 0;

  top->query_rob_idx_i = 0;
}

void eval_comb(Vtb_rob_exception *top) {
  top->clk_i = 0;
  top->eval();
}

void tick(Vtb_rob_exception *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

void reset(Vtb_rob_exception *top) {
  top->rst_ni = 0;
  clear_inputs(top);
  tick(top);
  tick(top);
  top->rst_ni = 1;
  tick(top);
}

void test_sync_exception_not_direct_flush(Vtb_rob_exception *top) {
  clear_inputs(top);
  top->dispatch_valid_i = 1;
  top->dispatch_pc_i = kFaultPc;
  top->dispatch_fu_type_i = kFuLsu;
  top->dispatch_has_rd_i = 1;
  top->dispatch_areg_i = 10;
  eval_comb(top);
  expect(top->rob_ready_o == 1, "dispatch accepted");
  tick(top);

  clear_inputs(top);
  top->wb_valid_i = 1;
  top->wb_rob_index_i = 0;
  top->wb_data_i = kFaultTval;
  top->wb_exception_i = 1;
  top->wb_ecause_i = kPageFault;
  eval_comb(top);
  tick(top);

  clear_inputs(top);
  eval_comb(top);
  expect(top->sync_exception_valid_o == 1, "sync exception pending exposed");
  expect(top->sync_exception_cause_o == kPageFault, "sync exception cause");
  expect(top->sync_exception_pc_o == kFaultPc, "sync exception pc");
  expect(top->sync_exception_tval_o == kFaultTval, "sync exception tval");
  expect(top->flush_o == 0, "sync exception should not directly flush ROB");
}

void test_async_exception_redirect_flush(Vtb_rob_exception *top) {
  clear_inputs(top);
  top->async_exception_valid_i = 1;
  top->async_exception_cause_i = kPageFault;
  top->async_exception_pc_i = kFaultPc;
  top->async_exception_redirect_pc_i = kTrapVector;
  eval_comb(top);
  expect(top->flush_o == 1, "async exception flush asserted");
  expect(top->flush_is_exception_o == 1, "async exception flush type");
  expect(top->flush_cause_o == kPageFault, "async exception cause");
  expect(top->flush_pc_o == kTrapVector, "async exception redirect pc");
  expect(top->flush_src_pc_o == kFaultPc, "async exception source pc");
}

void test_query_not_ready_after_commit(Vtb_rob_exception *top) {
  clear_inputs(top);
  top->dispatch_valid_i = 1;
  top->dispatch_pc_i = 0x81000000u;
  top->dispatch_fu_type_i = kFuLsu;
  top->dispatch_has_rd_i = 1;
  top->dispatch_areg_i = 5;
  eval_comb(top);
  expect(top->rob_ready_o == 1, "dispatch for query test accepted");
  tick(top);

  clear_inputs(top);
  top->wb_valid_i = 1;
  top->wb_rob_index_i = 0;
  top->wb_data_i = 0x12345678u;
  eval_comb(top);
  tick(top);

  // Commit this finished entry so ROB slot 0 is no longer in-flight.
  clear_inputs(top);
  eval_comb(top);
  tick(top);

  // Query old idx=0. Correct behavior: not ready because entry is retired.
  clear_inputs(top);
  top->query_rob_idx_i = 0;
  eval_comb(top);
  expect((top->query_ready_o & 0x1) == 0,
         "retired ROB entry must not appear ready on query port");
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_rob_exception;

  reset(top);
  test_sync_exception_not_direct_flush(top);
  test_async_exception_redirect_flush(top);
  test_query_not_ready_after_commit(top);

  std::cout << "--- ALL TESTS PASSED ---\n";
  delete top;
  return 0;
}
