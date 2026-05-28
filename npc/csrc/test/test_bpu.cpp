#include "Vtb_bpu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <iostream>

const int INSTR_PER_FETCH = 4;
const int NRET = 4;
void tick(Vtb_bpu *top, int cnt = 1) {
  while (cnt--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

void reset(Vtb_bpu *top) {
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

static void expect_not_taken(Vtb_bpu *top, uint32_t pc) {
  top->pc_i = pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 0);
  assert(top->npc_o == pc + 16);
}

static void expect_taken(Vtb_bpu *top, uint32_t pc, uint32_t target,
                         uint32_t slot_idx = 0) {
  top->pc_i = pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == slot_idx);
  assert(top->pred_slot_target_o == target);
  assert(top->npc_o == target);
}

static void train(Vtb_bpu *top, uint32_t pc, bool is_cond, bool taken,
                  uint32_t target, bool is_call = false, bool is_ret = false,
                  bool is_rvc = false) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = is_cond ? 1 : 0;
  top->update_taken_i = taken ? 1 : 0;
  top->update_target_i = target;
  top->update_is_call_i = is_call ? 1 : 0;
  top->update_is_ret_i = is_ret ? 1 : 0;
  top->update_is_rvc_i = is_rvc ? 1 : 0;
  top->ras_update_valid_i = (is_call || is_ret) ? 0x1 : 0x0;
  top->ras_update_is_call_i = is_call ? 0x1 : 0x0;
  top->ras_update_is_ret_i = is_ret ? 0x1 : 0x0;
  top->ras_update_is_rvc_i = is_call && is_rvc ? 0x1 : 0x0;
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

static void test_cond_alias_isolation(Vtb_bpu *top) {
  reset(top);

  const uint32_t pc_a = 0x80000120;
  const uint32_t pc_b = 0x80001120;
  const uint32_t target_a = 0x80004000;
  const uint32_t target_b = 0x80005000;

  // Train A to strongly-taken.
  train(top, pc_a, true, true, target_a);
  train(top, pc_a, true, true, target_a);

  // Train B on the same legacy index: overwrite BTB tag, then pull BHT to NT.
  train(top, pc_b, true, true, target_b);
  train(top, pc_b, true, false, target_b);
  train(top, pc_b, true, false, target_b);

  // With hashed indexing, A and B should no longer destroy each other.
  expect_taken(top, pc_a, target_a, 0);
  expect_not_taken(top, pc_b);
}

static void test_backward_cond_bias(Vtb_bpu *top) {
  reset(top);

  const uint32_t backward_pc = 0x80002000;
  const uint32_t backward_target = 0x80001fe0;
  const uint32_t forward_pc = 0x80002200;
  const uint32_t forward_target = 0x80002240;

  // Force weak-NT(01): taken once then not-taken once.
  train(top, backward_pc, true, true, backward_target);
  train(top, backward_pc, true, false, backward_target);

  // Backward loop branch should still be predicted taken with bias.
  expect_taken(top, backward_pc, backward_target, 0);

  train(top, forward_pc, true, true, forward_target);
  train(top, forward_pc, true, false, forward_target);

  // Forward weak-NT should remain not-taken.
  expect_not_taken(top, forward_pc);
}

static void test_spec_ghr_advances_on_predicted_conditional(Vtb_bpu *top) {
  reset(top);

  const uint32_t cond_pc = 0x80000c00;
  const uint32_t cond_target = 0x80000c40;

  // Train to strongly-taken so prediction will fire a conditional-taken event.
  train(top, cond_pc, true, true, cond_target);
  train(top, cond_pc, true, true, cond_target);

  uint32_t ghr_before = top->dbg_ghr_o;
  top->pc_i = cond_pc;
  top->ifu_valid_i = 1;
  top->ifu_ready_i = 1;
  tick(top, 1);  // prediction consumed
  tick(top, 1);  // allow speculative event to update history
  uint32_t ghr_after = top->dbg_ghr_o;

  // Without speculative GHR update, ghr_before==ghr_after.
  assert(ghr_after != ghr_before);
}

static void test_indirect_multitarget_context_switch(Vtb_bpu *top) {
  reset(top);

  const uint32_t cond1_pc = 0x80000100;
  const uint32_t cond1_tgt = 0x80000120;
  const uint32_t cond2_pc = 0x80000140;
  const uint32_t cond2_tgt = 0x80000160;
  const uint32_t indir_pc = 0x80000200;
  const uint32_t indir_tgt_a = 0x80008000;
  const uint32_t indir_tgt_b = 0x80009000;

  train(top, cond1_pc, true, true, cond1_tgt);
  train(top, cond1_pc, true, true, cond1_tgt);
  train(top, cond2_pc, true, true, cond2_tgt);
  train(top, cond2_pc, true, true, cond2_tgt);

  for (int i = 0; i < 8; i++) {
    top->pc_i = cond1_pc;
    tick(top, 1);
    train(top, indir_pc, false, true, indir_tgt_a);

    top->pc_i = cond1_pc;
    tick(top, 1);
    top->pc_i = cond2_pc;
    tick(top, 1);
    train(top, indir_pc, false, true, indir_tgt_b);
  }

  top->pc_i = cond1_pc;
  tick(top, 1);
  top->pc_i = indir_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == indir_tgt_a);
}

static void test_halfword_btb_alias(Vtb_bpu *top) {
  reset(top);

  const uint32_t branch_pc = 0x800010ec;
  const uint32_t alias_pc = branch_pc + 2;
  const uint32_t branch_target = 0x80000040;

  train(top, branch_pc, false, true, branch_target);

  top->pc_i = alias_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 0);
  assert(top->npc_o == alias_pc + 16);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_bpu *top = new Vtb_bpu;
  reset(top);

  // 1) Cold start: default not-taken.
  expect_not_taken(top, 0x80000000);

  // 1.1) Unaligned fetch-group base must still advance by FETCH_WIDTH
  // (not by align_group(pc) + FETCH_WIDTH), otherwise frontend may refetch
  // overlapping instructions after redirect.
  expect_not_taken(top, 0x80000114);

  // 1.2) For unaligned fetch base, prediction slot index is relative to fetch pc.
  // Train a JAL at 0x80000084 (aligned-group slot1). Fetch at 0x84 should see
  // it as local slot0; fetch at 0x88 must not see this branch in-window.
  const uint32_t jal_pc = 0x80000084;
  const uint32_t jal_target = 0x80000028;
  train(top, jal_pc, false, true, jal_target);

  top->pc_i = jal_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->npc_o == jal_target);

  top->pc_i = 0x80000088;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 0);
  assert(top->npc_o == 0x80000098);

  // 2) Train conditional branch as taken, expect taken prediction.
  // group pc = 0x80000040, branch pc = +8 => slot2.
  const uint32_t group_pc = 0x80000040;
  const uint32_t br_pc = group_pc + 8;
  const uint32_t br_target = 0x80000100;

  train(top, br_pc, true, true, br_target);
  train(top, br_pc, true, true, br_target); // drive counter to strongly taken

  top->pc_i = group_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 2);
  assert(top->pred_slot_target_o == br_target);
  assert(top->npc_o == br_target);

  // 3) Hysteresis: one not-taken keeps prediction taken, second flips to NT.
  train(top, br_pc, true, false, br_target);
  top->pc_i = group_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->npc_o == br_target);

  train(top, br_pc, true, false, br_target);
  expect_not_taken(top, group_pc);

  // 4) Window-aware arbitration: if multiple taken branches are in one fetch
  // window, predictor must choose the earliest slot in window.
  const uint32_t win_base = 0x80000100;
  const uint32_t early_br_pc = win_base + 4;   // slot1
  const uint32_t late_br_pc = win_base + 12;   // slot3
  const uint32_t early_target = 0x80001000;
  const uint32_t late_target = 0x80002000;

  // Train both as strongly-taken.
  train(top, early_br_pc, true, true, early_target);
  train(top, early_br_pc, true, true, early_target);
  train(top, late_br_pc, true, true, late_target);
  train(top, late_br_pc, true, true, late_target);

  // Base window: [base+0, +4, +8, +12], earliest taken is slot1.
  top->pc_i = win_base;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 1);
  assert(top->pred_slot_target_o == early_target);
  assert(top->npc_o == early_target);

  // Unaligned base window: [base+4, +8, +12, +16], earliest taken is now slot0.
  top->pc_i = win_base + 4;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == early_target);
  assert(top->npc_o == early_target);

  // 5) Speculative call->return:
  // Call prediction pushes RAS on next cycle, so following return should use it.
  reset(top);
  const uint32_t ret_pc = 0x80000300;
  const uint32_t ret_btb_target = 0x90000000;
  const uint32_t call_pc = 0x80000220;
  const uint32_t call_target = 0x80001000;

  train(top, ret_pc, false, true, ret_btb_target, false, true);
  train(top, call_pc, false, true, call_target, true, false);

  top->pc_i = call_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == call_target);
  assert(top->npc_o == call_target);

  top->pc_i = ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == call_pc + 4);
  assert(top->npc_o == call_pc + 4);

  // 6) Return underflow fallback:
  // The previous return prediction pops speculative RAS on next cycle.
  top->pc_i = ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == ret_btb_target);
  assert(top->npc_o == ret_btb_target);

  // 7) Nested call/return should follow LIFO order.
  reset(top);
  const uint32_t ret2_pc = 0x80000320;
  const uint32_t ret2_btb_target = 0x90000020;
  const uint32_t call_a_pc = 0x80000440;
  const uint32_t call_b_pc = 0x80000460;

  train(top, ret2_pc, false, true, ret2_btb_target, false, true);
  train(top, call_a_pc, false, true, 0x80002000, true, false);
  train(top, call_b_pc, false, true, 0x80003000, true, false);

  top->pc_i = call_a_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == 0x80002000);
  assert(top->npc_o == 0x80002000);

  top->pc_i = call_b_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == 0x80003000);
  assert(top->npc_o == 0x80003000);

  top->pc_i = ret2_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == call_b_pc + 4);
  assert(top->npc_o == call_b_pc + 4);

  top->pc_i = ret2_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == call_a_pc + 4);
  assert(top->npc_o == call_a_pc + 4);

  // 8) Optimistic return policy:
  // Return prediction prioritizes live RAS top over stale BTB return target.
  reset(top);
  const uint32_t stale_call_pc = 0x80000500;
  const uint32_t stale_ret_pc = 0x80000520;
  const uint32_t stale_ret_btb_target = 0x80000540;
  const uint32_t later_call_pc = 0x80000580;

  train(top, stale_ret_pc, false, true, stale_ret_btb_target, false, true);
  train(top, stale_call_pc, false, true, 0x80003000, true, false);
  train(top, later_call_pc, false, true, 0x80004000, true, false);

  top->pc_i = stale_call_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == 0x80003000);

  top->pc_i = later_call_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == 0x80004000);

  top->pc_i = stale_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == later_call_pc + 4);
  assert(top->npc_o == later_call_pc + 4);

  // 9) Empty-RAS fallback then speculative override.
  reset(top);
  const uint32_t spec_call_pc = 0x80000600;
  const uint32_t spec_ret_pc = 0x80000640;
  const uint32_t spec_ret_btb_target = 0x90000640;

  train(top, spec_call_pc, false, true, 0x80006000, true, false);
  train(top, spec_ret_pc, false, true, spec_ret_btb_target, false, true);

  top->pc_i = spec_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == spec_ret_btb_target);
  assert(top->npc_o == spec_ret_btb_target);

  top->pc_i = spec_call_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == 0x80006000);

  top->pc_i = spec_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == spec_call_pc + 4);
  assert(top->npc_o == spec_call_pc + 4);

  // 10) Flush-aware speculative RAS recover:
  // Pollute speculative top with wrong call, then flush should recover spec RAS
  // back to architectural RAS snapshot.
  reset(top);
  const uint32_t rec_ret_pc = 0x80000700;
  const uint32_t rec_ret_btb_target = 0x90000700;
  const uint32_t rec_base_call_pc = 0x80000720;
  const uint32_t rec_wrong_call_pc = 0x80000740;

  train(top, rec_ret_pc, false, true, rec_ret_btb_target, false, true);             // mark return
  train(top, rec_base_call_pc, false, true, 0x80007000, true, false);                // arch push base+4
  train(top, rec_wrong_call_pc, false, true, 0x80008000, true, false);               // arch push wrong+4
  train(top, rec_ret_pc, false, true, rec_wrong_call_pc + 4, false, true);           // arch pop wrong, arch back to base

  top->pc_i = rec_base_call_pc;  // spec push base+4
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == 0x80007000);

  top->pc_i = rec_wrong_call_pc;  // spec push wrong+4 (pollute)
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == 0x80008000);

  top->pc_i = rec_ret_pc;  // polluted top should win before flush
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == rec_wrong_call_pc + 4);

  top->flush_i = 1;  // recover speculative stack from architectural stack
  tick(top, 1);
  top->flush_i = 0;

  top->pc_i = rec_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == rec_base_call_pc + 4);
  assert(top->npc_o == rec_base_call_pc + 4);

  // 11) flush + commit-update same cycle:
  // flush recover should observe architectural update effect in the same cycle.
  const uint32_t sync_ret_target = 0x80000990;
  top->update_valid_i = 1;
  top->update_pc_i = rec_ret_pc;
  top->update_is_cond_i = 0;
  top->update_taken_i = 1;
  top->update_target_i = sync_ret_target;
  top->update_is_call_i = 0;
  top->update_is_ret_i = 1;  // pop architectural stack from base-only to empty
  top->update_is_rvc_i = 0;
  top->ras_update_valid_i = 0x1;
  top->ras_update_is_call_i = 0x0;
  top->ras_update_is_ret_i = 0x1;
  top->ras_update_is_rvc_i = 0x0;
  top->ras_update_pc_i[0] = rec_ret_pc;
  top->flush_i = 1;
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
  top->flush_i = 0;

  top->pc_i = rec_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  // If recover uses updated architectural state, stack is empty and return falls back BTB target.
  assert(top->pred_slot_target_o == sync_ret_target);
  assert(top->npc_o == sync_ret_target);

  // 12) IFU protocol compatibility:
  // IFU consumes prediction with ready-pulse while valid can be low (WAIT state).
  // BPU must still record speculative call/ret events in this pattern.
  reset(top);
  const uint32_t ifu_proto_call_pc = 0x80000a00;
  const uint32_t ifu_proto_call_target = 0x8000a000;
  const uint32_t ifu_proto_ret_pc = 0x80000a20;
  const uint32_t ifu_proto_ret_btb_target = 0x90000a20;

  train(top, ifu_proto_ret_pc, false, true, ifu_proto_ret_btb_target, false, true);
  train(top, ifu_proto_call_pc, false, true, ifu_proto_call_target, true, false);

  // START state: valid=1, ready=0 (request in-flight)
  top->ifu_valid_i = 1;
  top->ifu_ready_i = 0;
  top->pc_i = ifu_proto_call_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == ifu_proto_call_target);

  // WAIT state consume: valid=0, ready=1
  top->ifu_valid_i = 0;
  top->ifu_ready_i = 1;
  tick(top, 1);

  // Next return should observe speculative push from the consumed call.
  top->ifu_valid_i = 1;
  top->ifu_ready_i = 1;
  top->pc_i = ifu_proto_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == ifu_proto_call_pc + 4);
  assert(top->npc_o == ifu_proto_call_pc + 4);

  // 13) Multi-commit RAS updates in one cycle must be replayed in-order.
  reset(top);
  const uint32_t batch_ret_pc = 0x80000b00;
  const uint32_t batch_ret_btb_target = 0x90000b00;
  const uint32_t batch_call_a_pc = 0x80000b20;
  const uint32_t batch_call_b_pc = 0x80000b40;

  train(top, batch_ret_pc, false, true, batch_ret_btb_target, false, true);

  top->ras_update_valid_i = 0x3;     // slot0 + slot1
  top->ras_update_is_call_i = 0x3;   // push A then B
  top->ras_update_is_ret_i = 0x0;
  top->ras_update_is_rvc_i = 0x0;
  top->ras_update_pc_i[0] = batch_call_a_pc;
  top->ras_update_pc_i[1] = batch_call_b_pc;
  tick(top, 1);
  top->ras_update_valid_i = 0;
  top->ras_update_is_call_i = 0;
  top->ras_update_is_ret_i = 0;
  top->ras_update_is_rvc_i = 0;
  top->ras_update_pc_i[0] = 0;
  top->ras_update_pc_i[1] = 0;

  top->flush_i = 1;
  tick(top, 1);
  top->flush_i = 0;

  top->pc_i = batch_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == batch_call_b_pc + 4);

  top->ras_update_valid_i = 0x3;    // pop twice
  top->ras_update_is_call_i = 0x0;
  top->ras_update_is_ret_i = 0x3;
  top->ras_update_is_rvc_i = 0x0;
  tick(top, 1);
  top->ras_update_valid_i = 0;
  top->ras_update_is_call_i = 0;
  top->ras_update_is_ret_i = 0;
  top->ras_update_is_rvc_i = 0;

  top->flush_i = 1;
  tick(top, 1);
  top->flush_i = 0;

  top->pc_i = batch_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == batch_ret_btb_target);

  // 14) Compressed call must push return PC+2, not PC+4.
  reset(top);
  const uint32_t c_ret_pc = 0x80000c80;
  const uint32_t c_ret_btb_target = 0x90000c80;
  const uint32_t c_call_pc = 0x80000c6e;
  const uint32_t c_call_target = 0x8000c000;

  train(top, c_ret_pc, false, true, c_ret_btb_target, false, true, false);
  train(top, c_call_pc, false, true, c_call_target, true, false, true);

  top->pc_i = c_call_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == c_call_target);

  top->pc_i = c_ret_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_target_o == c_call_pc + 2);
  assert(top->npc_o == c_call_pc + 2);

  // 14) Hashed index should isolate previously aliased conditional branches.
  test_cond_alias_isolation(top);

  // 15) Backward-branch bias should rescue weak-NT loops only.
  test_backward_cond_bias(top);

  // 16) Global history should advance on predicted conditional branches
  // even before commit update returns from backend.
  test_spec_ghr_advances_on_predicted_conditional(top);

  // 17) Indirect branch target should be selected by path context.
  test_indirect_multitarget_context_switch(top);

  // 18) RV32C halfword-neighbor PCs must not alias in BTB/BHT lookup.
  test_halfword_btb_alias(top);

  std::cout << "--- [PASSED] All checks passed successfully! ---" << std::endl;
  delete top;
  return 0;
}
