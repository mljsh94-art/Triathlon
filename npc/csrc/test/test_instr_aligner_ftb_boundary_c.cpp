// FTB 半字 offset — 边界 C（RVC / 指令边界）aligner 单元测试
//
// 对应计划 §C：
//   C1  RVC 分支 @ 压缩指令起始半字 → is_rvc=1，taken 绑 target / 否则 pc+2
//   C2  32-bit 分支 @ 偶半字 → is_rvc=0，两半字组成 32-bit
//   C3  32-bit @ 奇半字 → 组内正确展开；carry 完成路径 pred_npc=pc+4（不可 taken）
//   C4  32-bit 跨 group 边界 → 本 group 产生 carry，下一 group 拼接
//   C5  pred_taken 落在非指令末半字 → 不截断（aliasing 防护）
//
// 审核通过后运行（WSL，SIM_MAIN 需绝对路径）：
//   cd /mnt/d/sjj_ict2026/Triathlon
//   make -C npc TOPNAME=tb_instr_aligner_ftb_boundary_c \
//     SIM_MAIN=$PWD/npc/csrc/test/test_instr_aligner_ftb_boundary_c.cpp -B
//   ./npc/build/tb_instr_aligner_ftb_boundary_c
#include "Vtb_instr_aligner_ftb_boundary_c.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

namespace {

constexpr int kInstrPerFetch = 4;
constexpr int kPredSlotCount = 8;
constexpr int kFeExpandMax = 8;

constexpr uint16_t kCnop = 0x0001;
constexpr uint16_t kCj = 0xa002;       // RVC c.j
constexpr uint32_t kJalX0 = 0x0000006f;

void tick(Vtb_instr_aligner_ftb_boundary_c *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

void reset(Vtb_instr_aligner_ftb_boundary_c *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->fe_valid_i = 0;
  top->ibuf_aln_ready_i = 1;
  top->fe_pc_i = 0;
  top->fe_slot_valid_i = 0;
  top->fe_pred_taken_i = 0;
  for (int w = 0; w < kInstrPerFetch; ++w) {
    top->fe_instrs_i[w] = 0;
  }
  top->fe_ftq_id_i = 0;
  top->fe_fetch_epoch_i = 0;
  for (int h = 0; h < kPredSlotCount; ++h) {
    top->fe_pred_npc_i[h] = 0;
  }
  tick(top);
  tick(top);
  top->rst_ni = 1;
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

uint32_t entry_pc(Vtb_instr_aligner_ftb_boundary_c *top, int idx) {
  return top->aln_pcs_o[idx];
}

uint32_t entry_npc(Vtb_instr_aligner_ftb_boundary_c *top, int idx) {
  return top->aln_pred_npc_o[idx];
}

uint32_t entry_instr(Vtb_instr_aligner_ftb_boundary_c *top, int idx) {
  return top->aln_instrs_o[idx];
}

bool entry_is_rvc(Vtb_instr_aligner_ftb_boundary_c *top, int idx) {
  return (top->aln_is_rvc_o >> idx) & 1;
}

void clear_pred_meta(Vtb_instr_aligner_ftb_boundary_c *top, uint32_t base_pc) {
  top->fe_slot_valid_i = 0;
  top->fe_pred_taken_i = 0;
  for (int h = 0; h < kPredSlotCount; ++h) {
    top->fe_pred_npc_i[h] = base_pc + static_cast<uint32_t>(h * 2 + 2);
  }
}

void set_pred_meta(Vtb_instr_aligner_ftb_boundary_c *top, uint32_t base_pc,
                   uint8_t slot_valid_mask, uint8_t pred_taken_mask) {
  top->fe_slot_valid_i = slot_valid_mask;
  top->fe_pred_taken_i = pred_taken_mask;
  for (int h = 0; h < kPredSlotCount; ++h) {
    top->fe_pred_npc_i[h] = base_pc + static_cast<uint32_t>(h * 2 + 2);
  }
}

void set_pred_target(Vtb_instr_aligner_ftb_boundary_c *top, int hw, uint32_t target) {
  top->fe_pred_npc_i[hw] = target;
}

// 组合态观察（不推进 carry 状态）
void eval_group(Vtb_instr_aligner_ftb_boundary_c *top, uint32_t base_pc,
                const uint32_t words[kInstrPerFetch], uint8_t slot_valid_mask,
                uint8_t pred_taken_mask) {
  top->fe_pc_i = base_pc;
  for (int w = 0; w < kInstrPerFetch; ++w) {
    top->fe_instrs_i[w] = words[w];
  }
  set_pred_meta(top, base_pc, slot_valid_mask, pred_taken_mask);
  top->fe_valid_i = 1;
  top->clk_i = 0;
  top->eval();
}

// fe_fire：推进一拍并更新 carry 状态
void fire_group(Vtb_instr_aligner_ftb_boundary_c *top, uint32_t base_pc,
                const uint32_t words[kInstrPerFetch], uint8_t slot_valid_mask,
                uint8_t pred_taken_mask) {
  eval_group(top, base_pc, words, slot_valid_mask, pred_taken_mask);
  tick(top);
  top->fe_valid_i = 0;
}

// C1: RVC 分支 @ 压缩指令起始半字
void test_c1_rvc_branch(Vtb_instr_aligner_ftb_boundary_c *top) {
  constexpr const char *kCase = "C1";
  reset(top);

  const uint32_t base = 0x00001000;
  const uint32_t target = 0x00002000;
  const uint32_t words[kInstrPerFetch] = {
      (static_cast<uint32_t>(kCj) << 16) | kCnop,  // hw0=c.nop, hw1=c.j
      0, 0, 0,
  };

  // taken @ hw1
  eval_group(top, base, words, 0x03, 0x02);
  set_pred_target(top, 1, target);
  top->eval();
  expect(top->aln_entry_count_o == 2, kCase, "expect 2 entries before taken truncate");
  expect(entry_pc(top, 0) == base, kCase, "first entry pc");
  expect(entry_is_rvc(top, 0), kCase, "c.nop is_rvc");
  expect(entry_npc(top, 0) == base + 2, kCase, "c.nop fall-through");
  expect(entry_pc(top, 1) == base + 2, kCase, "branch pc");
  expect(entry_is_rvc(top, 1), kCase, "branch is_rvc");
  expect(entry_npc(top, 1) == target, kCase, "taken branch target");
  fire_group(top, base, words, 0x03, 0x02);

  // not-taken fall-through
  reset(top);
  eval_group(top, base, words, 0x03, 0x00);
  top->eval();
  expect(entry_npc(top, 1) == base + 4, kCase, "RVC branch NT fall-through pc+2");
  std::cout << "[PASS][" << kCase << "] RVC branch @ compressed start half-word\n";
}

// C2: 32-bit 分支 @ 偶半字
void test_c2_rv32_even_half(Vtb_instr_aligner_ftb_boundary_c *top) {
  constexpr const char *kCase = "C2";
  reset(top);

  const uint32_t base = 0x00003000;
  const uint32_t target = 0x00004000;
  const uint32_t words[kInstrPerFetch] = {kJalX0, kCnop, 0, 0};

  eval_group(top, base, words, 0x03, 0x02);
  set_pred_target(top, 1, target);
  top->eval();
  expect(top->aln_entry_count_o == 1, kCase, "single 32-bit entry before truncate");
  expect(entry_pc(top, 0) == base, kCase, "32-bit pc aligned");
  expect(!entry_is_rvc(top, 0), kCase, "32-bit is_rvc=0");
  expect(entry_instr(top, 0) == kJalX0, kCase, "32-bit opcode");
  expect(entry_npc(top, 0) == target, kCase, "taken target on end half-word");

  reset(top);
  eval_group(top, base, words, 0x03, 0x00);
  top->eval();
  expect(entry_npc(top, 0) == base + 4, kCase, "32-bit NT fall-through pc+4");
  std::cout << "[PASS][" << kCase << "] 32-bit branch @ even half-word start\n";
}

// C3: 32-bit @ 奇半字 + carry 路径不可 taken
void test_c3_odd_half_and_carry(Vtb_instr_aligner_ftb_boundary_c *top) {
  constexpr const char *kCase = "C3";
  reset(top);

  // 奇半字起始：hw0=c.nop, hw1-hw2 组成 jal @ 0x1002
  const uint32_t base = 0x00005000;
  const uint32_t words[kInstrPerFetch] = {
      (static_cast<uint32_t>(kJalX0 & 0xFFFFu) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | 0u,
      0,
      0,
  };

  eval_group(top, base, words, 0x07, 0x00);
  top->eval();
  expect(top->aln_entry_count_o >= 2, kCase, "expect multiple entries");
  expect(entry_pc(top, 0) == base, kCase, "leading c.nop pc");
  expect(entry_is_rvc(top, 0), kCase, "leading c.nop is_rvc");
  expect(entry_pc(top, 1) == base + 2, kCase, "odd-start 32-bit pc");
  expect(!entry_is_rvc(top, 1), kCase, "odd-start 32-bit is_rvc=0");
  expect(entry_instr(top, 1) == kJalX0, kCase, "odd-start jal opcode");
  expect(entry_npc(top, 1) == base + 6, kCase, "odd-start jal fall-through");

  // carry 完成：上一 group 在 hw6 留下 32-bit 低半字（PC+12），hw7 不在预测范围内
  reset(top);
  const uint32_t g1_base = 0x00006000;
  const uint32_t g1_words[kInstrPerFetch] = {
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | static_cast<uint32_t>(kJalX0 & 0xFFFFu),
  };
  fire_group(top, g1_base, g1_words, 0x7F, 0x00);
  expect(top->aln_carry_valid_o, kCase, "expect carry after low-half at group end");
  expect(top->aln_carry_pc_o == g1_base + 12, kCase, "carry pc at odd 32-bit start");

  const uint32_t g2_base = g1_base + 16;
  const uint32_t g2_words[kInstrPerFetch] = {
      static_cast<uint32_t>(kJalX0 >> 16),
      kCnop,
      0,
      0,
  };
  eval_group(top, g2_base, g2_words, 0xFF, 0x01);
  set_pred_target(top, 0, 0x0000BEEFu);
  top->eval();
  expect(top->aln_entry_count_o >= 1, kCase, "carry completion emits entry");
  expect(entry_pc(top, 0) == g1_base + 12, kCase, "carry entry uses saved pc");
  expect(!entry_is_rvc(top, 0), kCase, "carry 32-bit is_rvc=0");
  expect(entry_npc(top, 0) == g1_base + 16, kCase, "carry pred_npc fall-through pc+4");
  expect(entry_npc(top, 0) != 0x0000BEEFu, kCase, "carry ignores pred_taken on hw0");
  std::cout << "[PASS][" << kCase << "] odd-half 32-bit + carry no-taken path\n";
}

// C4: 32-bit 跨 group 边界 → carry 到下一 group
void test_c4_cross_group_carry(Vtb_instr_aligner_ftb_boundary_c *top) {
  constexpr const char *kCase = "C4";
  reset(top);

  const uint32_t g1_base = 0x00007000;
  const uint32_t g1_words[kInstrPerFetch] = {
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      (static_cast<uint32_t>(kCnop) << 16) | static_cast<uint32_t>(kJalX0 & 0xFFFFu),
  };
  fire_group(top, g1_base, g1_words, 0x7F, 0x00);
  expect(top->aln_carry_valid_o, kCase, "group1 should set carry for spanning 32-bit");
  expect(top->aln_carry_half_o == static_cast<uint16_t>(kJalX0 & 0xFFFFu), kCase,
         "carry half is low 16b of jal");

  const uint32_t g2_base = g1_base + 16;
  const uint32_t g2_words[kInstrPerFetch] = {
      static_cast<uint32_t>(kJalX0 >> 16),
      0,
      0,
      0,
  };
  eval_group(top, g2_base, g2_words, 0x01, 0x00);
  top->eval();
  expect(entry_pc(top, 0) == g1_base + 12, kCase, "completed inst pc from prior group");
  expect(entry_instr(top, 0) == kJalX0, kCase, "completed jal opcode");
  fire_group(top, g2_base, g2_words, 0x01, 0x00);
  expect(!top->aln_carry_valid_o, kCase, "carry consumed after second group");
  std::cout << "[PASS][" << kCase << "] 32-bit spans fetch group via carry\n";
}

// C5: pred_taken 落在 32-bit 低半字（非末半字）→ 不截断
void test_c5_spurious_low_half_taken(Vtb_instr_aligner_ftb_boundary_c *top) {
  constexpr const char *kCase = "C5";
  reset(top);

  const uint32_t base = 0x00008000;
  const uint32_t words[kInstrPerFetch] = {
      kJalX0,
      (static_cast<uint32_t>(kCnop) << 16) | kCnop,
      0,
      0,
  };

  // 误标 pred_taken[0]（32-bit 低半字），末半字 hw1 无 taken
  eval_group(top, base, words, 0x0F, 0x01);
  set_pred_target(top, 0, 0x0000DEADu);
  top->eval();
  expect(top->aln_entry_count_o >= 2, kCase, "must not truncate on spurious low-half taken");
  expect(entry_pc(top, 0) == base, kCase, "32-bit entry emitted");
  expect(!entry_is_rvc(top, 0), kCase, "32-bit entry");
  expect(entry_npc(top, 0) == base + 4, kCase, "uses end-half taken semantics → fall-through");
  expect(entry_npc(top, 0) != 0x0000DEADu, kCase, "ignore pred_taken on non-end half");
  expect(entry_pc(top, 1) == base + 4, kCase, "subsequent half-word still expanded");
  std::cout << "[PASS][" << kCase << "] spurious taken on 32-bit low half ignored\n";
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_instr_aligner_ftb_boundary_c *top = new Vtb_instr_aligner_ftb_boundary_c;

  std::cout << "=== FTB boundary C — instr_aligner RVC/instr-boundary tests ===\n";
  test_c1_rvc_branch(top);
  test_c2_rv32_even_half(top);
  test_c3_odd_half_and_carry(top);
  test_c4_cross_group_carry(top);
  test_c5_spurious_low_half_taken(top);

  std::cout << "--- [PASSED] FTB boundary C (aligner) ---\n";
  delete top;
  return 0;
}
