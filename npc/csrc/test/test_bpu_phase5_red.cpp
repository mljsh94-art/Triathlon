#include "Vtb_bpu_phase5_red.h"
#include "verilated.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

constexpr int kNret = 4;

void tick(Vtb_bpu_phase5_red *top, int cnt = 1) {
  while (cnt--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

void reset(Vtb_bpu_phase5_red *top) {
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
  for (int i = 0; i < kNret; i++) {
    top->ras_update_pc_i[i] = 0;
  }
  top->flush_i = 0;
  top->pc_i = 0x80000000;
  tick(top, 5);
  top->rst_i = 0;
  tick(top, 1);
}

void train(Vtb_bpu_phase5_red *top, uint32_t pc, bool is_cond, bool taken,
           uint32_t target, bool is_call = false, bool is_ret = false) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = is_cond ? 1 : 0;
  top->update_taken_i = taken ? 1 : 0;
  top->update_target_i = target;
  top->update_is_call_i = is_call ? 1 : 0;
  top->update_is_ret_i = is_ret ? 1 : 0;
  top->update_is_rvc_i = 0;
  top->ras_update_valid_i = (is_call || is_ret) ? 0x1 : 0x0;
  top->ras_update_is_call_i = is_call ? 0x1 : 0x0;
  top->ras_update_is_ret_i = is_ret ? 0x1 : 0x0;
  top->ras_update_is_rvc_i = 0x0;
  top->ras_update_pc_i[0] = pc;
  tick(top, 1);
  top->update_valid_i = 0;
  top->update_is_call_i = 0;
  top->update_is_ret_i = 0;
  top->update_is_rvc_i = 0;
  top->ras_update_valid_i = 0;
  top->ras_update_is_call_i = 0;
  top->ras_update_is_ret_i = 0;
  top->ras_update_is_rvc_i = 0;
  top->ras_update_pc_i[0] = 0;
}

void predict_once(Vtb_bpu_phase5_red *top, uint32_t pc) {
  top->pc_i = pc;
  top->ifu_valid_i = 1;
  top->ifu_ready_i = 1;
  tick(top, 1);
}

void test_indirect_multitarget_needs_ittage(Vtb_bpu_phase5_red *top) {
  reset(top);

  const uint32_t cond1_pc = 0x80000100;
  const uint32_t cond1_tgt = 0x80000120;
  const uint32_t cond2_pc = 0x80000140;
  const uint32_t cond2_tgt = 0x80000160;
  const uint32_t indir_pc = 0x80000200;
  const uint32_t indir_tgt_a = 0x80008000;
  const uint32_t indir_tgt_b = 0x80009000;

  // Warm up two always-taken branches to create two distinct path contexts.
  train(top, cond1_pc, true, true, cond1_tgt);
  train(top, cond1_pc, true, true, cond1_tgt);
  train(top, cond2_pc, true, true, cond2_tgt);
  train(top, cond2_pc, true, true, cond2_tgt);

  // Context A: one taken cond before indirect -> target A.
  // Context B: two taken conds before indirect -> target B.
  for (int i = 0; i < 8; i++) {
    predict_once(top, cond1_pc);
    train(top, indir_pc, false, true, indir_tgt_a);

    predict_once(top, cond1_pc);
    predict_once(top, cond2_pc);
    train(top, indir_pc, false, true, indir_tgt_b);
  }

  // Red expectation for ITTAGE: under context A we expect target A.
  // Current single-target BTB collapses to last target (usually B), so this fails.
  predict_once(top, cond1_pc);
  predict_once(top, indir_pc);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == indir_tgt_a);
}

void test_ras_checkpoint_needs_ftq_rollback(Vtb_bpu_phase5_red *top) {
  reset(top);

  const uint32_t call_pc = 0x80000300;
  const uint32_t call_target = 0x80003000;
  const uint32_t ret_pc = 0x80000320;
  const uint32_t ret_fallback_target = 0x90000320;

  train(top, ret_pc, false, true, ret_fallback_target, false, true);
  train(top, call_pc, false, true, call_target, true, false);

  // Speculatively push call return address.
  predict_once(top, call_pc);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == call_target);

  // Simulate branch recovery that should rollback to per-FTQ checkpoint,
  // preserving older in-flight call context instead of full arch reset.
  top->flush_i = 1;
  tick(top, 1);
  top->flush_i = 0;

  predict_once(top, ret_pc);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == call_pc + 4);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_bpu_phase5_red;

  test_indirect_multitarget_needs_ittage(top);
  test_ras_checkpoint_needs_ftq_rollback(top);

  std::cout << "--- [PASSED] Phase5 ITTAGE/RAS checks passed ---" << std::endl;
  delete top;
  return 0;
}
