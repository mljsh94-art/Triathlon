#include "Vtb_sc_l.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>

static void tick(Vtb_sc_l *top, int cycles = 1) {
  while (cycles--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_sc_l *top) {
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

static void train(Vtb_sc_l *top, uint32_t pc, uint8_t ghr, bool taken) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_ghr_i = ghr;
  top->update_taken_i = taken ? 1 : 0;
  tick(top, 1);
  top->update_valid_i = 0;
}

static void predict(Vtb_sc_l *top, uint32_t base_pc, uint8_t ghr) {
  top->predict_base_pc_i = base_pc;
  top->predict_ghr_i = ghr;
  tick(top, 1);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_sc_l;
  reset(top);

  const uint32_t base_pc = 0x80000100;
  const uint32_t branch_pc = base_pc + 8; // slot2
  const uint32_t slot_mask = 1u << 2;
  const uint8_t ghr = 0x5a;

  predict(top, base_pc, ghr);
  assert((top->predict_confident_o & slot_mask) == 0);

  for (int i = 0; i < 6; i++) {
    train(top, branch_pc, ghr, true);
  }
  predict(top, base_pc, ghr);
  assert((top->predict_taken_o & slot_mask) != 0);
  assert((top->predict_confident_o & slot_mask) != 0);

  for (int i = 0; i < 12; i++) {
    train(top, branch_pc, ghr, false);
  }
  predict(top, base_pc, ghr);
  assert((top->predict_taken_o & slot_mask) == 0);
  assert((top->predict_confident_o & slot_mask) != 0);

  std::cout << "--- [PASSED] SC-L saturating correction behavior ---" << std::endl;
  delete top;
  return 0;
}
