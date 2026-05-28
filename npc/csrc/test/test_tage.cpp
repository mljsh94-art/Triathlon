#include "Vtb_tage.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>

static void tick(Vtb_tage *top, int cycles = 1) {
  while (cycles--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_tage *top) {
  top->rst_i = 1;
  top->predict_base_pc_i = 0;
  top->predict_ghr_i = 0;
  top->update_valid_i = 0;
  top->update_pc_i = 0;
  top->update_ghr_i = 0;
  top->update_taken_i = 0;
  tick(top, 4);
  top->rst_i = 0;
  tick(top, 1);
}

static void train(Vtb_tage *top, uint32_t pc, uint8_t ghr, bool taken) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_ghr_i = ghr;
  top->update_taken_i = taken ? 1 : 0;
  tick(top, 1);
  top->update_valid_i = 0;
}

static void predict(Vtb_tage *top, uint32_t base_pc, uint8_t ghr) {
  top->predict_base_pc_i = base_pc;
  top->predict_ghr_i = ghr;
  tick(top, 1);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_tage;
  reset(top);

  const uint32_t branch_pc = 0x80000108;
  const uint32_t base_pc = 0x80000100;
  const uint32_t slot_idx = (branch_pc - base_pc) / 4;
  const uint32_t slot_mask = (1u << slot_idx);

  // Same low history bits, different long history bits.
  const uint8_t hist_taken = 0x03;    // 0000_0011
  const uint8_t hist_not_taken = 0xC3; // 1100_0011

  // Alternate contradictory outcomes under two contexts.
  for (int i = 0; i < 24; i++) {
    train(top, branch_pc, hist_taken, true);
    train(top, branch_pc, hist_not_taken, false);
  }

  predict(top, base_pc, hist_taken);
  bool taken_pred = ((top->predict_hit_o & slot_mask) != 0) &&
                    ((top->predict_taken_o & slot_mask) != 0);

  predict(top, base_pc, hist_not_taken);
  bool not_taken_pred = ((top->predict_hit_o & slot_mask) != 0) &&
                        ((top->predict_taken_o & slot_mask) == 0);

  assert(taken_pred && "TAGE should predict taken for long-history context A");
  assert(not_taken_pred && "TAGE should predict not-taken for long-history context B");

  std::cout << "--- [PASSED] TAGE long-history context separation ---" << std::endl;
  delete top;
  return 0;
}
