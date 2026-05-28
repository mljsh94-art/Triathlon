#include "Vtb_bpu_tournament.h"
#include "verilated.h"
#include <cassert>
#include <iostream>

const int NRET = 4;

static void tick(Vtb_bpu_tournament *top, int cnt = 1) {
  while (cnt--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_bpu_tournament *top) {
  top->rst_i = 1;
  top->ifu_ready_i = 1;
  top->ifu_valid_i = 1;
  top->update_valid_i = 0;
  top->update_pc_i = 0;
  top->update_is_cond_i = 0;
  top->update_taken_i = 0;
  top->update_target_i = 0;
  top->update_is_call_i = 0;
  top->update_is_ret_i = 0;
  top->update_is_rvc_i = 0;
  top->ras_update_valid_i = 0;
  top->ras_update_is_call_i = 0;
  top->ras_update_is_ret_i = 0;
  top->ras_update_is_rvc_i = 0;
  for (int i = 0; i < NRET; i++) {
    top->ras_update_pc_i[i] = 0;
  }
  top->flush_i = 0;
  top->pc_i = 0x80000000;
  tick(top, 5);
  top->rst_i = 0;
  tick(top, 1);
}

static void train(Vtb_bpu_tournament *top, uint32_t pc, bool taken,
                  uint32_t target) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = 1;
  top->update_taken_i = taken ? 1 : 0;
  top->update_target_i = target;
  top->update_is_call_i = 0;
  top->update_is_ret_i = 0;
  top->update_is_rvc_i = 0;
  top->ras_update_valid_i = 0;
  top->ras_update_is_call_i = 0;
  top->ras_update_is_ret_i = 0;
  top->ras_update_is_rvc_i = 0;
  tick(top, 1);
  top->update_valid_i = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_bpu_tournament;
  reset(top);

  // BHT entries=8, GHR_BITS=1:
  // victim idx: 010 (pc=0x...08) with h=0 -> global idx 010
  // poison idx: 101 (pc=0x...14) with h=1 -> global idx 101 ^ 111 = 010
  // They alias in global table but stay separated in local table.
  const uint32_t ctx_pc = 0x80000000;
  const uint32_t victim_pc = 0x80000008;
  const uint32_t poison_pc = 0x80000014;
  const uint32_t ctx_target = 0x80000100;
  const uint32_t victim_target = 0x80000200;
  const uint32_t poison_target = 0x80000300;

  // Build strong taken local/global state for victim branch.
  train(top, ctx_pc, false, ctx_target);      // h=0
  train(top, victim_pc, true, victim_target); // install BTB + train taken
  train(top, ctx_pc, false, ctx_target);      // h=0
  train(top, victim_pc, true, victim_target);

  // Repeatedly poison the shared global entry with not-taken.
  for (int i = 0; i < 4; i++) {
    train(top, ctx_pc, true, ctx_target);       // h=1
    train(top, poison_pc, false, poison_target); // decrement shared global entry
  }

  // Set h=0 for victim prediction path.
  train(top, ctx_pc, false, ctx_target);
  top->pc_i = victim_pc;
  tick(top, 1);

  // Tournament predictor should still choose local and keep victim taken.
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == victim_target);
  assert(top->npc_o == victim_target);

  std::cout << "--- [PASSED] tournament predictor local/global arbitration ---"
            << std::endl;
  delete top;
  return 0;
}
