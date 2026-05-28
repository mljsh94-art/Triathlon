#include "Vtb_bpu_tage.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>

const int NRET = 4;

static void tick(Vtb_bpu_tage *top, int cnt = 1) {
  while (cnt--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_bpu_tage *top) {
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

static void train(Vtb_bpu_tage *top, uint32_t pc, bool taken, uint32_t target) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = 1;
  top->update_taken_i = taken ? 1 : 0;
  top->update_target_i = target;
  top->update_is_rvc_i = 0;
  tick(top, 1);
  top->update_valid_i = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_bpu_tage *top = new Vtb_bpu_tage;
  reset(top);

  const uint32_t group_pc = 0x80001000;
  const uint32_t br_pc = group_pc + 8;
  const uint32_t br_target = 0x80002000;

  // Pattern with frequent direction changes to exercise TAGE update/lookup path.
  for (int i = 0; i < 256; ++i) {
    bool taken = ((i % 7) != 0) && ((i % 5) != 0);
    train(top, br_pc, taken, br_target);
    top->pc_i = group_pc;
    tick(top, 1);
  }

  uint64_t lookup_total = top->dbg_tage_lookup_total_o;
  uint64_t hit_total = top->dbg_tage_hit_total_o;
  uint64_t override_total = top->dbg_tage_override_total_o;
  uint64_t override_correct = top->dbg_tage_override_correct_o;

  assert(lookup_total >= 128 && "TAGE lookup counter should increase with conditional updates");
  assert(hit_total > 0 && "TAGE hit counter should be non-zero after training");
  assert(hit_total <= lookup_total);
  assert(override_correct <= override_total);

  std::cout << "--- [PASSED] BPU TAGE integration counters ---" << std::endl;
  std::cout << "lookup=" << lookup_total << " hit=" << hit_total
            << " override=" << override_total
            << " override_correct=" << override_correct << std::endl;
  delete top;
  return 0;
}
