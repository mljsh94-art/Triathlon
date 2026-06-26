#include "Vtb_rob_exception.h"
#include "verilated.h"

#include <cstdlib>
#include <cstring>
#include <iostream>

namespace {

constexpr uint32_t kFuAlu = 1;

Vtb_rob_exception *g_top = nullptr;

void clear_inputs(Vtb_rob_exception *top) {
  top->flush_i = 0;

  top->dispatch_valid_i = 0;
  top->dispatch_pc_i = 0;
  top->dispatch_fu_type_i = 0;
  top->dispatch_areg_i = 0;
  top->dispatch_has_rd_i = 0;
  top->dispatch_is_branch_i = 0;
  top->dispatch_is_store_i = 0;
  top->dispatch_st_id_i = 0;

  top->wb_valid_i = 0;
  top->wb_rob_index_i = 0;
  top->wb_data_i = 0;
  top->wb_exception_i = 0;
  top->wb_ecause_i = 0;
  top->wb_is_mispred_i = 0;
  top->wb_redirect_pc_i = 0;
  top->wb_valid2_i = 0;
  top->wb_rob_index2_i = 0;
  top->wb_data2_i = 0;

  top->async_exception_valid_i = 0;
  top->async_exception_cause_i = 0;
  top->async_exception_pc_i = 0;
  top->async_exception_redirect_pc_i = 0;

  top->query_rob_idx_i = 0;
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

void fill_rob(Vtb_rob_exception *top) {
  for (int i = 0; i < 8; i++) {
    clear_inputs(top);
    top->dispatch_valid_i = 1;
    top->dispatch_pc_i = static_cast<uint32_t>(0x81000000u + i * 4u);
    top->dispatch_fu_type_i = kFuAlu;
    top->dispatch_has_rd_i = 0;
    tick(top);
  }
}

// N1: dispatch while ROB full -> rob/dispatch_while_full
void neg_dispatch_while_full(Vtb_rob_exception *top) {
  reset(top);
  fill_rob(top);

  clear_inputs(top);
  top->dispatch_valid_i = 1;
  top->dispatch_pc_i = 0x81000020u;
  top->dispatch_fu_type_i = kFuAlu;
  tick(top);
}

// N2: WB to retired/invalid tag -> rob/wb_to_invalid
void neg_wb_to_invalid(Vtb_rob_exception *top) {
  reset(top);

  clear_inputs(top);
  top->dispatch_valid_i = 1;
  top->dispatch_pc_i = 0x82000000u;
  top->dispatch_fu_type_i = kFuAlu;
  top->dispatch_has_rd_i = 1;
  top->dispatch_areg_i = 3;
  tick(top);

  clear_inputs(top);
  top->wb_valid_i = 1;
  top->wb_rob_index_i = 0;
  top->wb_data_i = 0x55u;
  tick(top);

  clear_inputs(top);
  tick(top);

  clear_inputs(top);
  top->wb_valid_i = 1;
  top->wb_rob_index_i = 0;
  top->wb_data_i = 0xAAu;
  top->clk_i = 0;
  top->eval();
}

// N3: same-cycle dual WB with duplicate tag -> rob/wb_duplicate_tag
void neg_wb_duplicate_tag(Vtb_rob_exception *top) {
  reset(top);

  clear_inputs(top);
  top->dispatch_valid_i = 1;
  top->dispatch_pc_i = 0x83000000u;
  top->dispatch_fu_type_i = kFuAlu;
  top->dispatch_has_rd_i = 0;
  tick(top);

  clear_inputs(top);
  top->wb_valid_i = 1;
  top->wb_rob_index_i = 0;
  top->wb_data_i = 0x11u;
  top->wb_valid2_i = 1;
  top->wb_rob_index2_i = 0;
  top->wb_data2_i = 0x22u;
  top->clk_i = 0;
  top->eval();
}

int parse_neg_test(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (std::strncmp(argv[i], "+neg_test=", 10) == 0) {
      return std::atoi(argv[i] + 10);
    }
  }
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const int neg_test = parse_neg_test(argc, argv);
  if (neg_test < 1 || neg_test > 3) {
    std::cerr << "usage: tb_rob_exception +neg_test={1|2|3}\n";
    std::cerr << "  1 = rob/dispatch_while_full\n";
    std::cerr << "  2 = rob/wb_to_invalid\n";
    std::cerr << "  3 = rob/wb_duplicate_tag\n";
    return 2;
  }

  g_top = new Vtb_rob_exception;

  switch (neg_test) {
    case 1:
      neg_dispatch_while_full(g_top);
      break;
    case 2:
      neg_wb_to_invalid(g_top);
      break;
    case 3:
      neg_wb_duplicate_tag(g_top);
      break;
    default:
      break;
  }

  std::cerr << "[neg] assertion did not fire for neg_test=" << neg_test << "\n";
  delete g_top;
  return 1;
}
