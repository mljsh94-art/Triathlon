// FTB 半字 offset — 边界 A3/A1 IFU 半字展开单元测试
//
// 验证 IFU 将 FTQ pred_slot_idx（末半字 index）展开为：
//   slot_valid[h] = (h <= pred_slot_idx)
//   pred_taken[h] = (h == pred_slot_idx)
//   taken 半字 pred_npc = target；A1 无 taken 时 8 半字全 valid、pred_taken=0
//
// 审核通过后运行（WSL，SIM_MAIN 需绝对路径）：
//   cd /mnt/d/sjj_ict2026/Triathlon
//   make -C npc TOPNAME=tb_ifu_ftb_boundary_a \
//     SIM_MAIN=$PWD/npc/csrc/test/test_ifu_ftb_boundary_a.cpp -B
//   ./npc/build/tb_ifu_ftb_boundary_a
#include "Vtb_ifu_ftb_boundary_a.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

namespace {

constexpr int kPredSlotCount = 8;
constexpr int kInstrPerFetch = 4;

void tick(Vtb_ifu_ftb_boundary_a *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

void reset(Vtb_ifu_ftb_boundary_a *top) {
  top->rst_i = 1;
  top->flush_i = 0;
  top->redirect_pc_i = 0;
  top->ftq_deq_valid_i = 0;
  top->ftq_deq_pc_i = 0;
  top->ftq_deq_pred_slot_valid_i = 0;
  top->ftq_deq_pred_slot_idx_i = 0;
  top->ftq_deq_pred_target_i = 0;
  top->ftq_deq_pred_npc_i = 0;
  top->icache_rsp_valid_i = 0;
  for (int i = 0; i < kInstrPerFetch; ++i) {
    top->icache_rsp_data_i[i] = 0x00000013;  // nop
  }
  top->ibuf_ready_i = 1;
  tick(top);
  tick(top);
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

uint32_t get_pred_npc(Vtb_ifu_ftb_boundary_a *top, int hw) {
  return top->ibuf_pred_npc_o[hw];
}

bool fetch_and_wait_ibuf(Vtb_ifu_ftb_boundary_a *top, uint32_t fetch_pc,
                         bool pred_slot_valid, uint32_t pred_slot_idx,
                         uint32_t pred_target, uint32_t pred_npc) {
  top->ftq_deq_pc_i = fetch_pc;
  top->ftq_deq_pred_slot_valid_i = pred_slot_valid ? 1 : 0;
  top->ftq_deq_pred_slot_idx_i = pred_slot_idx;
  top->ftq_deq_pred_target_i = pred_target;
  top->ftq_deq_pred_npc_i = pred_npc;
  top->ftq_deq_valid_i = 1;
  top->icache_rsp_valid_i = 0;

  for (int cycle = 0; cycle < 64; ++cycle) {
    top->eval();
    if (top->icache_req_valid_o) {
      top->icache_rsp_valid_i = 1;
    }
    if (top->ibuf_valid_o && top->ibuf_ready_i) {
      tick(top);
      top->ftq_deq_valid_i = 0;
      top->icache_rsp_valid_i = 0;
      return true;
    }
    tick(top);
  }
  top->ftq_deq_valid_i = 0;
  return false;
}

void expect_slot_mask(Vtb_ifu_ftb_boundary_a *top, const char *case_id,
                      uint8_t expect_valid, uint8_t expect_taken) {
  uint8_t got_valid = static_cast<uint8_t>(top->ibuf_slot_valid_o);
  uint8_t got_taken = static_cast<uint8_t>(top->ibuf_pred_taken_o);
  if (got_valid != expect_valid) {
    std::cerr << "[FAIL][" << case_id << "] slot_valid expect=0x" << std::hex
              << int(expect_valid) << " got=0x" << int(got_valid) << std::dec << '\n';
    std::exit(1);
  }
  if (got_taken != expect_taken) {
    std::cerr << "[FAIL][" << case_id << "] pred_taken expect=0x" << std::hex
              << int(expect_taken) << " got=0x" << int(got_taken) << std::dec << '\n';
    std::exit(1);
  }
}

// A1 @ IFU：无 taken 截断 → 8 半字全 valid，pred_taken 全 0
void test_a1_ifu_all_valid(Vtb_ifu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A1-IFU";
  reset(top);

  const uint32_t fetch_pc = 0x80000000;
  expect(fetch_and_wait_ibuf(top, fetch_pc, false, 0, 0, fetch_pc + 16), kCase,
         "IFU did not produce ibuffer response");
  expect(top->ibuf_pc_o == fetch_pc, kCase, "ibuf pc mismatch");
  expect_slot_mask(top, kCase, 0xFF, 0x00);
  std::cout << "[PASS][" << kCase << "] no truncate → 8 hw valid, pred_taken=0\n";
}

// A3 @ IFU：taken 末半字 idx=N → valid[0:N]=1, taken[N]=1, pred_npc[N]=target
void test_a3_ifu_taken_truncate(Vtb_ifu_ftb_boundary_a *top) {
  constexpr const char *kCase = "A3-IFU";
  struct Case {
    uint32_t fetch_pc;
    uint32_t slot_idx;
    uint32_t target;
    uint8_t valid_mask;
    uint8_t taken_mask;
  };
  const Case cases[] = {
      {0x00001000, 1, 0x00002000, 0x03, 0x02},  // A4 同 idx=1
      {0x00001000, 3, 0x00003000, 0x0F, 0x08},  // RVC @ 0x1006
      {0x00003000, 5, 0x00004000, 0x3F, 0x20},  // 32-bit @ word2
      {0x00003000, 7, 0x00005000, 0xFF, 0x80},  // 32-bit @ word3 末半字
  };

  for (const auto &c : cases) {
    reset(top);
    expect(fetch_and_wait_ibuf(top, c.fetch_pc, true, c.slot_idx, c.target, c.target),
           kCase, "IFU did not produce ibuffer response");
    expect(top->ibuf_pc_o == c.fetch_pc, kCase, "ibuf pc mismatch");
    expect_slot_mask(top, kCase, c.valid_mask, c.taken_mask);
    expect(get_pred_npc(top, c.slot_idx) == c.target, kCase,
           "taken half-word pred_npc should equal target");
  }
  std::cout << "[PASS][" << kCase << "] taken truncate slot_valid/pred_taken masks\n";
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ifu_ftb_boundary_a *top = new Vtb_ifu_ftb_boundary_a;

  std::cout << "=== FTB boundary A — IFU half-word expand tests ===\n";
  test_a1_ifu_all_valid(top);
  test_a3_ifu_taken_truncate(top);

  std::cout << "--- [PASSED] FTB boundary A (IFU) ---\n";
  delete top;
  return 0;
}
