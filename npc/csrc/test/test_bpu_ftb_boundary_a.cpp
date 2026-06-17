// FTB 半字 offset — 边界 A（预测命中/miss）BPU 单元测试
//
// 对应计划 §A：
//   A1  Block 无分支 / BTB miss → pred_slot_valid=0, npc=fetch_pc+16
//   A2  BTB hit 条件分支预测 not-taken → pred_slot_valid=0
//   A3  BTB hit 且 taken → pred_slot_idx=末半字 hw index, npc=target
//   A4  高半字 RVC 分支 (0x1002, offset=1) — 核心修复场景
//   A5  32-bit 分支偶半字 offset (0/2/4/6 → idx 1/3/5/7)
//   B1  同 block 多 cond → 选择 fetch_start 之后最早 taken
//   B2  同 block cond+jump → jump 早于 cond 时选择 jump
//   B3  fetch 从 block 中间开始 → 跳过 fetch_start 之前的 slot
//   B4  32-bit 分支跨 fetch group → 当前 slot0 高半字承载预测
//   B5  动态 fetch 窗口跨到下一 16B FTB block → lookup 命中 next block
//   C1  同 offset 再训练 → target 覆盖旧路径，不残留
//   C2  4 槽满后 LRU 替换 → 新 offset 写入新 target，不读 victim 旧 target
//
// 审核通过后运行（WSL，SIM_MAIN 需绝对路径）：
//   cd /mnt/d/sjj_ict2026/Triathlon
//   make -C npc TOPNAME=tb_bpu_ftb_boundary_a \
//     SIM_MAIN=$PWD/npc/csrc/test/test_bpu_ftb_boundary_a.cpp -B
//   ./npc/build/tb_bpu_ftb_boundary_a
#include "Vtb_bpu_ftb_boundary_a.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

namespace {

constexpr int kNret = 4;
constexpr uint32_t kFetchWidth = 16;

void tick(Vtb_bpu_ftb_boundary_a *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

void reset(Vtb_bpu_ftb_boundary_a *top) {
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
  for (int i = 0; i < kNret; ++i) {
    top->ras_update_pc_i[i] = 0;
  }
  top->flush_i = 0;
  top->pc_i = 0x80000000;
  for (int i = 0; i < 5; ++i) {
    tick(top);
  }
  top->rst_i = 0;
  tick(top);
}

[[noreturn]] void fail(const char *case_id, const char *msg) {
  std::cerr << "[FAIL][" << case_id << "] " << msg << '\n';
  std::exit(1);
}

void expect(bool cond, const char *case_id, const char *msg) {
  if (!cond) {
    fail(case_id, msg);
  }
}

void train(Vtb_bpu_ftb_boundary_a *top, uint32_t pc, bool is_cond, bool taken,
           uint32_t target, bool is_rvc = false) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = is_cond ? 1 : 0;
  top->update_taken_i = taken ? 1 : 0;
  top->update_target_i = target;
  top->update_is_call_i = 0;
  top->update_is_ret_i = 0;
  top->update_is_rvc_i = is_rvc ? 1 : 0;
  top->ras_update_valid_i = 0;
  tick(top);
  top->update_valid_i = 0;
  top->update_is_rvc_i = 0;
}

void predict_at(Vtb_bpu_ftb_boundary_a *top, uint32_t fetch_pc) {
  top->pc_i = fetch_pc;
  top->ifu_valid_i = 1;
  top->ifu_ready_i = 1;
  tick(top);
}

void expect_fallthrough(Vtb_bpu_ftb_boundary_a *top, const char *case_id,
                        uint32_t fetch_pc) {
  expect(top->pred_slot_valid_o == 0, case_id, "pred_slot_valid should be 0");
  expect(top->npc_o == fetch_pc + kFetchWidth, case_id,
         "npc should be fetch_pc + 16 (fall-through)");
  expect(top->ftq_enq_pc_o == fetch_pc, case_id, "ftq enq pc should match fetch pc");
}

void expect_taken(Vtb_bpu_ftb_boundary_a *top, const char *case_id, uint32_t fetch_pc,
                  uint32_t slot_idx, uint32_t target) {
  expect(top->pred_slot_valid_o == 1, case_id, "pred_slot_valid should be 1");
  expect(top->pred_slot_idx_o == slot_idx, case_id, "pred_slot_idx mismatch");
  expect(top->pred_slot_target_o == target, case_id, "pred_slot_target mismatch");
  expect(top->npc_o == target, case_id, "npc should equal branch target");
  expect(top->ftq_enq_pc_o == fetch_pc, case_id, "ftq enq pc should match fetch pc");
}

void train_strong_taken(Vtb_bpu_ftb_boundary_a *top, uint32_t pc, uint32_t target,
                        bool is_cond, bool is_rvc = false) {
  train(top, pc, is_cond, true, target, is_rvc);
  train(top, pc, is_cond, true, target, is_rvc);
}

void train_strong_not_taken(Vtb_bpu_ftb_boundary_a *top, uint32_t pc, uint32_t target) {
  train(top, pc, true, true, target);
  train(top, pc, true, false, target);
  train(top, pc, true, false, target);
}

// A1: BTB miss / 无分支 — 冷启动与未训练 PC
void test_a1_btb_miss(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A1";
  reset(top);
  predict_at(top, 0x80000000);
  expect_fallthrough(top, kCase, 0x80000000);

  predict_at(top, 0x80001000);
  expect_fallthrough(top, kCase, 0x80001000);
  std::cout << "[PASS][" << kCase << "] BTB miss / no branch → fall-through\n";
}

// A2: BTB hit 但条件分支预测 not-taken
void test_a2_cond_not_taken(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A2";
  reset(top);

  const uint32_t block = 0x80002000;
  const uint32_t br_pc = block + 8;
  const uint32_t target = 0x80003000;

  train_strong_taken(top, br_pc, target, true);
  train_strong_not_taken(top, br_pc, target);

  predict_at(top, block);
  expect_fallthrough(top, kCase, block);
  std::cout << "[PASS][" << kCase << "] cond hit but NT → no slot truncate\n";
}

// A3: BTB hit 且 taken — 半字末 index（RVC @ 0x1006 → idx=3）
void test_a3_taken_hw_index(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A3";
  reset(top);

  const uint32_t block = 0x00001000;
  const uint32_t br_pc = 0x00001006;  // half index 3
  const uint32_t target = 0x00002000;

  train_strong_taken(top, br_pc, target, false, true);

  predict_at(top, block);
  expect_taken(top, kCase, block, 3, target);
  std::cout << "[PASS][" << kCase << "] taken RVC @ hw3 → pred_slot_idx=3\n";
}

// A4: 高半字 RVC 分支 — PC=0x1002, FTB offset=1（核心修复）
void test_a4_high_half_rvc(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A4";
  reset(top);

  const uint32_t block = 0x00001000;
  const uint32_t br_pc = 0x00001002;
  const uint32_t target = 0x00002000;

  train(top, br_pc, false, true, target, true);

  predict_at(top, block);
  expect_taken(top, kCase, block, 1, target);
  std::cout << "[PASS][" << kCase << "] high-half RVC @ 0x1002 → pred_slot_idx=1\n";
}

// A5: 32-bit 分支偶半字 offset — idx = 2*word + 1
void test_a5_even_word_offsets(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A5";
  reset(top);

  const uint32_t block = 0x00003000;
  struct Case {
    uint32_t br_pc;
    uint32_t slot_idx;
  };
  const Case cases[] = {
      {block + 0, 1},
      {block + 4, 3},
      {block + 8, 5},
      {block + 12, 7},
  };

  for (const auto &c : cases) {
    reset(top);
    const uint32_t target = c.br_pc + 0x1000;
    train_strong_taken(top, c.br_pc, target, false, false);
    predict_at(top, block);
    expect_taken(top, kCase, block, c.slot_idx, target);
  }
  std::cout << "[PASS][" << kCase << "] 32-bit branches at even hw offsets 0/2/4/6\n";
}

// B1: 同 block 多个 taken cond — offset 较小者优先
void test_b1_multi_cond_first_taken(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "B1";
  reset(top);

  const uint32_t block = 0x00004000;
  const uint32_t late_pc = block + 8;
  const uint32_t early_pc = block + 4;
  const uint32_t late_target = 0x00005000;
  const uint32_t early_target = 0x00006000;

  train_strong_taken(top, late_pc, late_target, true);
  train_strong_taken(top, early_pc, early_target, true);

  predict_at(top, block);
  expect_taken(top, kCase, block, 3, early_target);
  std::cout << "[PASS][" << kCase << "] multi-cond in one block → earliest taken cond\n";
}

// B2: 同 block cond+jump — jump 默认 taken，且更早时优先
void test_b2_cond_jump_first_taken(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "B2";
  reset(top);

  const uint32_t block = 0x00007000;
  const uint32_t jump_pc = block + 4;
  const uint32_t cond_pc = block + 8;
  const uint32_t jump_target = 0x00008000;
  const uint32_t cond_target = 0x00009000;

  train_strong_taken(top, cond_pc, cond_target, true);
  train(top, jump_pc, false, true, jump_target, false);

  predict_at(top, block);
  expect_taken(top, kCase, block, 3, jump_target);
  std::cout << "[PASS][" << kCase << "] cond+jump in one block → earliest jump\n";
}

// B3: fetch 从 block 中间开始 — 只考虑 fetch_start 之后的 slot
void test_b3_fetch_from_middle(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "B3";
  reset(top);

  const uint32_t block = 0x0000A000;
  const uint32_t before_fetch_pc = block + 4;
  const uint32_t after_fetch_pc = block + 12;
  const uint32_t before_target = 0x0000B000;
  const uint32_t after_target = 0x0000C000;

  train(top, before_fetch_pc, false, true, before_target, false);
  train(top, after_fetch_pc, false, true, after_target, false);

  predict_at(top, block + 8);
  expect_taken(top, kCase, block + 8, 3, after_target);
  std::cout << "[PASS][" << kCase << "] mid-block fetch skips earlier slot\n";
}

// B4: 32-bit 分支低半字在上一 fetch 尾部，当前 fetch slot0 是高半字
void test_b4_carry_end_branch_slot0(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "B4";
  reset(top);

  const uint32_t block = 0x0000B000;
  const uint32_t br_pc = block + 2;
  const uint32_t fetch_pc = br_pc + 2;
  const uint32_t target = 0x0000C000;

  train_strong_taken(top, br_pc, target, true, false);

  predict_at(top, fetch_pc);
  expect_taken(top, kCase, fetch_pc, 0, target);
  std::cout << "[PASS][" << kCase << "] carry-end 32-bit branch predicts at slot0\n";
}

// B5: fetch 从上一 block 末尾开始，分支位于下一 16B FTB block
void test_b5_next_block_lookup(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "B5";
  reset(top);

  const uint32_t block = 0x0000C000;
  const uint32_t fetch_pc = block + 14;
  const uint32_t br_pc = block + 16;
  const uint32_t target = 0x0000D000;

  train_strong_taken(top, br_pc, target, true, true);

  predict_at(top, fetch_pc);
  expect_taken(top, kCase, fetch_pc, 1, target);
  std::cout << "[PASS][" << kCase << "] unaligned fetch sees next-block FTB slot\n";
}

// C1: 同 offset 命中更新 — 第二次训练应覆盖 target，预测不得沿用旧路径
void test_c1_same_offset_target_refresh(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "C1";
  reset(top);

  const uint32_t block = 0x0000D000;
  const uint32_t br_pc = block + 8;
  const uint32_t old_target = 0x0000E000;
  const uint32_t new_target = 0x0000F000;

  train_strong_taken(top, br_pc, old_target, true);
  predict_at(top, block);
  expect_taken(top, kCase, block, 5, old_target);

  train_strong_taken(top, br_pc, new_target, true);
  predict_at(top, block);
  expect_taken(top, kCase, block, 5, new_target);
  std::cout << "[PASS][" << kCase << "] same-offset retrain refreshes target\n";
}

// C2: 4 槽满后 LRU — 新 offset 必须携带新 target，不能误用被替换槽的旧 target
void test_c2_lru_replace_fresh_target(Vtb_bpu_ftb_boundary_a *top) {
  constexpr const char *kCase = "C2";
  reset(top);

  const uint32_t block = 0x0000E000;
  const uint32_t stale_target = 0xDEADBEEF;
  const uint32_t new_target = 0x0000F000;

  // 占满 4 槽；其中 slot0 的 target 设为明显 stale 值便于误用检测
  train(top, block + 0, false, true, stale_target, false);
  train(top, block + 4, false, true, block + 0x1000, false);
  train(top, block + 8, false, true, block + 0x2000, false);
  train(top, block + 12, false, true, block + 0x3000, false);

  // 第 5 条控制流：RVC @ 0xE002，应 LRU 替换并写入 new_target
  train(top, block + 2, false, true, new_target, true);

  predict_at(top, block + 2);
  expect_taken(top, kCase, block + 2, 0, new_target);
  expect(top->pred_slot_target_o != stale_target, kCase,
         "LRU slot must not reuse evicted stale target");
  std::cout << "[PASS][" << kCase << "] LRU replace writes fresh target at new offset\n";
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_bpu_ftb_boundary_a *top = new Vtb_bpu_ftb_boundary_a;

  std::cout << "=== FTB boundary A — BPU unit tests ===\n";
  test_a1_btb_miss(top);
  test_a2_cond_not_taken(top);
  test_a3_taken_hw_index(top);
  test_a4_high_half_rvc(top);
  test_a5_even_word_offsets(top);
  test_b1_multi_cond_first_taken(top);
  test_b2_cond_jump_first_taken(top);
  test_b3_fetch_from_middle(top);
  test_b4_carry_end_branch_slot0(top);
  test_b5_next_block_lookup(top);
  test_c1_same_offset_target_refresh(top);
  test_c2_lru_replace_fresh_target(top);

  std::cout << "--- [PASSED] FTB boundary A (BPU) ---\n";
  delete top;
  return 0;
}
