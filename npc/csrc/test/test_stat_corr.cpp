#include "Vtb_stat_corr.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>

static void tick(Vtb_stat_corr *top, int cycles = 1) {
  while (cycles--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

static void reset(Vtb_stat_corr *top) {
  top->rst_i = 1;
  top->predict_pc_i = 0;
  top->predict_ghr_i = 0;
  top->tage_taken_i = 0;
  top->tage_hit_i = 0;
  top->tage_conf_i = 0;
  top->update_valid_i = 0;
  top->update_pc_i = 0;
  top->update_ghr_i = 0;
  top->update_taken_i = 0;
  top->update_tage_taken_i = 0;
  top->update_tage_hit_i = 0;
  top->update_tage_conf_i = 0;
  tick(top, 4);
  top->rst_i = 0;
  tick(top, 1);
}

static void train(Vtb_stat_corr *top, uint32_t pc, uint32_t ghr, bool taken,
                  bool tage_taken, bool tage_hit, int tage_conf) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_ghr_i = ghr;
  top->update_taken_i = taken ? 1 : 0;
  top->update_tage_taken_i = tage_taken ? 1 : 0;
  top->update_tage_hit_i = tage_hit ? 1 : 0;
  top->update_tage_conf_i = tage_conf & 7;
  tick(top, 1);
  top->update_valid_i = 0;
}

static void predict(Vtb_stat_corr *top, uint32_t pc0, uint32_t pc1, uint32_t ghr,
                    uint8_t tage_taken_mask, uint8_t tage_hit_mask, uint8_t tage_conf_lane0,
                    uint8_t tage_conf_lane1) {
  top->predict_pc_i = ((uint64_t)pc1 << 32) | (uint64_t)pc0;
  top->predict_ghr_i = ghr;
  top->tage_taken_i = tage_taken_mask;
  top->tage_hit_i = tage_hit_mask;
  top->tage_conf_i = (uint32_t)((tage_conf_lane1 & 7) << 3) | (tage_conf_lane0 & 7);
  tick(top, 1);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_stat_corr;
  reset(top);

  const uint32_t pc = 0x80000108;
  const uint32_t ghr = 0x0000005a;
  // TAGE 弱 not-taken（居中 conf=0 -> tage_term=+1），命中 provider。
  const uint8_t tage_hit = 0x1;
  const uint8_t tage_nt = 0x0;
  const uint8_t conf0 = 0; // signed centered 0

  // ---- Case 1: |sum| 低于阈值 -> 不翻转 ----
  predict(top, pc, pc, ghr, tage_nt, tage_hit, conf0, conf0);
  assert((top->sc_use_o & 1) == 0 && "SC must not override when |sum| < threshold");

  // ---- Case 2: 充分训练后 SC 强反向 -> sc_use=1 且 sc_taken=1 ----
  for (int i = 0; i < 32; i++) {
    train(top, pc, ghr, true, false, true, conf0);
  }
  predict(top, pc, pc, ghr, tage_nt, tage_hit, conf0, conf0);
  assert((top->sc_taken_o & 1) != 0 && "GEHL sum should predict taken after training");
  assert((top->sc_use_o & 1) != 0 &&
         "SC should override weak TAGE not-taken when |sum| >= threshold");

  // ---- Case 3: TAGE 未命中 -> sc_use=0（即使 sum 很大）----
  predict(top, pc, pc, ghr, tage_nt, 0, conf0, conf0);
  assert((top->sc_use_o & 1) == 0 && "SC must not override when TAGE misses");

  // ---- Case 3b: TAGE 强置信 -> sc_use=0（即使 SC 方向相反）----
  const uint8_t conf_strong = 3; // signed centered +3
  predict(top, pc, pc, ghr, tage_nt, tage_hit, conf_strong, conf_strong);
  assert((top->sc_use_o & 1) == 0 && "SC must not override when TAGE is strong");

  // ---- Case 4: 2-lane 独立（lane1 不同 PC）----
  const uint32_t pc1 = 0x8000020c;
  for (int i = 0; i < 32; i++) {
    train(top, pc1, ghr, false, true, true, conf0);
  }
  predict(top, pc, pc1, ghr, 0x3, 0x3, conf0, conf0);
  assert((top->sc_taken_o & 1) != 0 && "lane0 should remain SC-taken");
  assert((top->sc_taken_o & 2) == 0 && "lane1 should SC-predict not-taken");
  assert((top->sc_use_o & 2) != 0 && "lane1 should override TAGE taken");

  // ---- Case 5: 自适应阈值 — SC 被采用且错 -> 阈值升高后弱 sum 不再翻转 ----
  reset(top);
  for (int i = 0; i < 10; i++) {
    train(top, pc, ghr, true, false, true, conf0);
  }
  predict(top, pc, pc, ghr, tage_nt, tage_hit, conf0, conf0);
  assert((top->sc_use_o & 1) != 0 && "need sc_use active before threshold test");

  // 多次 SC 被采用且预测错误，推动 thresh_q 上升。
  for (int i = 0; i < 12; i++) {
    predict(top, pc, pc, ghr, tage_nt, tage_hit, conf0, conf0);
    if ((top->sc_use_o & 1) == 0) break;
    train(top, pc, ghr, false, false, true, conf0);
  }
  predict(top, pc, pc, ghr, tage_nt, tage_hit, conf0, conf0);
  assert((top->sc_use_o & 1) == 0 &&
         "threshold should rise after repeated wrong SC overrides");

  std::cout << "--- [PASSED] stat_corr GEHL 2-lane calibration ---" << std::endl;
  delete top;
  return 0;
}
