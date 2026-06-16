// FTB 半字 offset — 边界 A（预测命中/miss）BPU 单元测试
//
// 对应计划 §A：
//   A1  Block 无分支 / BTB miss → pred_slot_valid=0, npc=fetch_pc+16
//   A2  BTB hit 条件分支预测 not-taken → pred_slot_valid=0
//   A3  BTB hit 且 taken → pred_slot_idx=末半字 hw index, npc=target
//   A4  高半字 RVC 分支 (0x1002, offset=1) — 核心修复场景
//   A5  32-bit 分支偶半字 offset (0/2/4/6 → idx 1/3/5/7)
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

  std::cout << "--- [PASSED] FTB boundary A (BPU) ---\n";
  delete top;
  return 0;
}
