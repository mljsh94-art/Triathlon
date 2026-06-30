#include "Vtb_tage.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>

static void tick(Vtb_tage *top, int cycles = 1) {
  while (cycles--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_tage *top) {
  top->rst_i = 1;
  top->predict_pc_i = 0;
  top->predict_ghr_i = 0;
  top->update_valid_i = 0;
  top->update_pc_i = 0;
  top->update_ghr_i = 0;
  top->update_taken_i = 0;
  tick(top, 4);
  top->rst_i = 0;
  tick(top, 1);
}

// 单写端口：commit 一次训练一条分支。
static void train(Vtb_tage *top, uint32_t pc, uint8_t ghr, bool taken) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_ghr_i = ghr;
  top->update_taken_i = taken ? 1 : 0;
  tick(top, 1);
  top->update_valid_i = 0;
}

// 2-lane predict：lane0 = pc0, lane1 = pc1，共享同一个 GHR。
static void predict(Vtb_tage *top, uint32_t pc0, uint32_t pc1, uint8_t ghr) {
  top->predict_pc_i = ((uint64_t)pc1 << 32) | (uint64_t)pc0;
  top->predict_ghr_i = ghr;
  tick(top, 1);
}

static bool lane_taken(Vtb_tage *top, int lane) {
  uint32_t mask = (1u << lane);
  return ((top->predict_hit_o & mask) != 0) && ((top->predict_taken_o & mask) != 0);
}

static bool lane_not_taken(Vtb_tage *top, int lane) {
  uint32_t mask = (1u << lane);
  return ((top->predict_hit_o & mask) != 0) && ((top->predict_taken_o & mask) == 0);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_tage;
  reset(top);

  const uint32_t pc_a = 0x80000108;
  const uint32_t pc_b = 0x80000204;

  // Same low history bits, different long history bits.
  const uint8_t hist_taken = 0x03;     // 0000_0011
  const uint8_t hist_not_taken = 0xC3; // 1100_0011

  // ---- Case 1: long-history context separation (single PC, two GHRs) ----
  for (int i = 0; i < 24; i++) {
    train(top, pc_a, hist_taken, true);
    train(top, pc_a, hist_not_taken, false);
  }

  // Both lanes read pc_a; lane direction must follow each lane's GHR-folded context.
  predict(top, pc_a, pc_a, hist_taken);
  bool ctx_a_taken = lane_taken(top, 0) && lane_taken(top, 1);

  predict(top, pc_a, pc_a, hist_not_taken);
  bool ctx_b_not_taken = lane_not_taken(top, 0) && lane_not_taken(top, 1);

  assert(ctx_a_taken && "TAGE should predict taken for long-history context A (both lanes)");
  assert(ctx_b_not_taken &&
         "TAGE should predict not-taken for long-history context B (both lanes)");

  // ---- Case 2: shared folded history across lanes (two PCs, same GHR) ----
  // Folded history depends only on the shared GHR; per-lane PC fold must still
  // separate the two branches, so each lane reads its own trained direction.
  for (int i = 0; i < 24; i++) {
    train(top, pc_b, hist_taken, false);
  }

  predict(top, pc_a, pc_b, hist_taken);
  bool lane0_taken = lane_taken(top, 0);    // pc_a under hist_taken -> taken
  bool lane1_not_taken = lane_not_taken(top, 1); // pc_b under hist_taken -> not-taken

  assert(lane0_taken &&
         "lane0 (pc_a, shared GHR) should keep its trained taken direction");
  assert(lane1_not_taken &&
         "lane1 (pc_b, shared GHR) should read its own not-taken direction");

  std::cout << "--- [PASSED] TAGE 2-lane context separation + shared folded history ---"
            << std::endl;
  delete top;
  return 0;
}
