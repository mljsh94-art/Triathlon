#include "Vtb_loop_predictor.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>

static void tick(Vtb_loop_predictor *top, int cycles = 1) {
  while (cycles--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_loop_predictor *top) {
  top->rst_i = 1;
  top->predict_base_pc_i = 0;
  top->update_valid_i = 0;
  top->update_pc_i = 0;
  top->update_is_cond_i = 0;
  top->update_taken_i = 0;
  tick(top, 4);
  top->rst_i = 0;
  tick(top, 1);
}

static void train(Vtb_loop_predictor *top, uint32_t pc, bool taken) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = 1;
  top->update_taken_i = taken ? 1 : 0;
  tick(top, 1);
  top->update_valid_i = 0;
}

static void predict(Vtb_loop_predictor *top, uint32_t base_pc) {
  top->predict_base_pc_i = base_pc;
  tick(top, 1);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_loop_predictor;
  reset(top);

  const uint32_t base_pc = 0x80000200;
  const uint32_t branch_pc = base_pc + 8; // slot2
  const uint32_t slot_mask = 1u << 2;

  // Teach a stable loop: taken,taken,taken,not-taken.
  for (int round = 0; round < 8; round++) {
    train(top, branch_pc, true);
    train(top, branch_pc, true);
    train(top, branch_pc, true);
    train(top, branch_pc, false);
  }

  // After training, predictor should be confident and hit.
  predict(top, base_pc);
  assert((top->predict_hit_o & slot_mask) != 0);
  assert((top->predict_confident_o & slot_mask) != 0);

  // In-loop iterations should predict taken.
  predict(top, base_pc);
  assert((top->predict_taken_o & slot_mask) != 0);
  train(top, branch_pc, true);

  predict(top, base_pc);
  assert((top->predict_taken_o & slot_mask) != 0);
  train(top, branch_pc, true);

  predict(top, base_pc);
  assert((top->predict_taken_o & slot_mask) != 0);
  train(top, branch_pc, true);

  // Loop exit should predict not-taken.
  predict(top, base_pc);
  assert((top->predict_confident_o & slot_mask) != 0);
  assert((top->predict_taken_o & slot_mask) == 0);
  train(top, branch_pc, false);

  std::cout << "--- [PASSED] loop predictor learns stable trip-count ---"
            << std::endl;
  delete top;
  return 0;
}
