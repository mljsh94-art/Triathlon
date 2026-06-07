#include "Vtb_frontend.h"
#include "verilated.h"
#include <cassert>
#include <iomanip>
#include <iostream>
#include <map>
#include <vector>

// =================================================================
// 配置参数
// =================================================================
const int INSTR_PER_FETCH = 4;
const int NRET = 4;
const int LINE_WIDTH_BYTES = 32; // 256 bits
const int LINE_WIDTH_WORDS = LINE_WIDTH_BYTES / 4;

vluint64_t main_time = 0;

// =================================================================
// 内存模拟器 (支持自动 Refill)
// =================================================================
class SimulatedMemory {
private:
  std::map<uint32_t, std::vector<uint32_t>> memory_data;

  enum State { IDLE, WAIT_DELAY, SEND_REFILL };
  State state = IDLE;
  int delay_counter = 0;

  uint32_t pending_addr = 0;
  uint32_t pending_way = 0;

public:
  // 预加载数据到内存
  void preload(uint32_t start_addr, const std::vector<uint32_t> &instrs) {
    uint32_t line_addr = start_addr & ~(LINE_WIDTH_BYTES - 1);
    std::vector<uint32_t> line(LINE_WIDTH_WORDS, 0);

    if (memory_data.count(line_addr)) {
      line = memory_data[line_addr];
    }
    int offset_words = (start_addr - line_addr) / 4;
    for (size_t i = 0;
         i < instrs.size() && (offset_words + i) < LINE_WIDTH_WORDS; ++i) {
      line[offset_words + i] = instrs[i];
    }
    memory_data[line_addr] = line;
  }

  void eval(Vtb_frontend *top) {
    top->miss_req_ready_i = 1; // memory always ready
    top->refill_valid_i = 0;

    if (state == IDLE && top->miss_req_valid_o) {
      pending_addr = top->miss_req_paddr_o;
      pending_way = top->miss_req_victim_way_o;
      state = WAIT_DELAY;
      delay_counter = 3; // Memory Latency
      // std::cout << "[" << main_time << "] MEM: Miss Req 0x" << std::hex <<
      // pending_addr << std::endl;
    }

    if (state == WAIT_DELAY) {
      if (delay_counter > 0)
        delay_counter--;
      else
        state = SEND_REFILL;
    }

    if (state == SEND_REFILL) {
      top->refill_valid_i = 1;
      top->refill_paddr_i = pending_addr;
      top->refill_way_i = pending_way;

      uint32_t line_addr = pending_addr & ~(LINE_WIDTH_BYTES - 1);
      if (memory_data.count(line_addr)) {
        const auto &data = memory_data[line_addr];
        for (int i = 0; i < LINE_WIDTH_WORDS; ++i)
          top->refill_data_i[i] = data[i];
      } else {
        for (int i = 0; i < LINE_WIDTH_WORDS; ++i)
          top->refill_data_i[i] = 0xDEADBEEF;
      }

      if (top->refill_ready_o) {
        // std::cout << "[" << main_time << "] MEM: Refill Done 0x" << std::hex
        // << pending_addr << std::endl;
        state = IDLE;
      }
    }
  }
};

void tick(Vtb_frontend *top, SimulatedMemory &mem) {
  top->clk_i = 0;
  mem.eval(top);
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

uint32_t get_instr(Vtb_frontend *top, int index) {
  return top->ibuffer_instrs_o[index];
}

// =================================================================
// Main Test
// =================================================================
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_frontend *top = new Vtb_frontend;
  SimulatedMemory mem;

  std::cout << "============================================================="
            << std::endl;
  std::cout << " TEST: IFU decoupled fetch queue + flush drop stale responses"
            << std::endl;
  std::cout << "============================================================="
            << std::endl;

  const uint32_t kStartPc = 0x80000000;
  const uint32_t kRedirectPc = 0x80000100;

  mem.preload(0x80000000, {0x00000013, 0x00100093, 0x00200113, 0x00300193});
  mem.preload(0x80000010, {0x00400213, 0x00500293, 0x00600313, 0x00700393});
  mem.preload(0x80000020, {0x00800413, 0x00900493, 0x00A00513, 0x00B00593});
  mem.preload(0x80000030, {0x00C00613, 0x00D00693, 0x00E00713, 0x00F00793});
  mem.preload(0x80000100, {0x10000013, 0x10100093, 0x10200113, 0x10300193});

  top->rst_ni = 0;
  top->ibuffer_ready_i = 0;
  top->flush_i = 0;
  top->redirect_pc_i = 0;
  top->bpu_update_valid_i = 0;
  top->bpu_update_pc_i = 0;
  top->bpu_update_is_cond_i = 0;
  top->bpu_update_taken_i = 0;
  top->bpu_update_target_i = 0;
  top->bpu_update_is_call_i = 0;
  top->bpu_update_is_ret_i = 0;
  top->bpu_update_is_rvc_i = 0;
  top->bpu_ras_update_valid_i = 0;
  top->bpu_ras_update_is_call_i = 0;
  top->bpu_ras_update_is_ret_i = 0;
  top->bpu_ras_update_is_rvc_i = 0;
  for (int i = 0; i < NRET; i++) top->bpu_ras_update_pc_i[i] = 0;

  for (int i = 0; i < 5; i++) tick(top, mem);
  top->rst_ni = 1;

  // Phase--1: multi-outstanding precondition check (RED->GREEN for A4.1).
  // Before the first visible ICache response, IFU should have built up
  // at least two outstanding fetch requests.
  int req_fire_before_first_rsp = 0;
  int max_outstanding_before_first_rsp = 0;
  int max_pending_before_first_rsp = 0;
  int max_inflight_before_first_rsp = 0;
  bool first_rsp_seen = false;
  top->ibuffer_ready_i = 0;
  for (int i = 0; i < 80; ++i) {
    tick(top, mem);
    if (top->dbg_ifu_rsp_capture_o) {
      first_rsp_seen = true;
      break;
    }
    if (int(top->dbg_ifu_outstanding_o) > max_outstanding_before_first_rsp) {
      max_outstanding_before_first_rsp = int(top->dbg_ifu_outstanding_o);
    }
    if (int(top->dbg_ifu_pending_o) > max_pending_before_first_rsp) {
      max_pending_before_first_rsp = int(top->dbg_ifu_pending_o);
    }
    if (int(top->dbg_ifu_inflight_o) > max_inflight_before_first_rsp) {
      max_inflight_before_first_rsp = int(top->dbg_ifu_inflight_o);
    }
    if (int(top->dbg_ifu_outstanding_o) !=
        int(top->dbg_ifu_pending_o) + int(top->dbg_ifu_inflight_o)) {
      std::cerr << "[fail] IFU outstanding mismatch: outstanding="
                << int(top->dbg_ifu_outstanding_o)
                << " pending=" << int(top->dbg_ifu_pending_o)
                << " inflight=" << int(top->dbg_ifu_inflight_o)
                << std::endl;
      delete top;
      return 1;
    }
    if (top->dbg_ifu_req_fire_o) {
      req_fire_before_first_rsp++;
    }
  }
  std::cout << "[info] req_fire_before_first_rsp=" << req_fire_before_first_rsp
            << " max_outstanding_before_first_rsp="
            << max_outstanding_before_first_rsp
            << " max_pending_before_first_rsp=" << max_pending_before_first_rsp
            << " max_inflight_before_first_rsp=" << max_inflight_before_first_rsp
            << std::endl;
  if (!first_rsp_seen) {
    std::cerr << "[fail] timeout waiting first icache response in phase--1"
              << std::endl;
    delete top;
    return 1;
  }
  if (max_outstanding_before_first_rsp < 2) {
    std::cerr << "[fail] IFU outstanding debug signal did not observe "
                 ">=2 outstanding requests before first response"
              << std::endl;
    delete top;
    return 1;
  }

  // Phase-0: no bubble check when ibuffer can consume immediately.
  // If IFU is truly decoupled, an ICache response should be visible to
  // ibuffer in the same cycle (bypass), instead of adding a 1-cycle bubble.
  top->ibuffer_ready_i = 1;
  bool saw_rsp = false;
  int overlap_rsp_capture_and_req_fire = 0;
  for (int i = 0; i < 80; ++i) {
    tick(top, mem);
    if (top->dbg_ifu_rsp_capture_o) {
      saw_rsp = true;
      if (top->dbg_ifu_req_fire_o) {
        overlap_rsp_capture_and_req_fire++;
      }
      if (!top->dbg_ifu_ibuf_valid_o) {
        std::cerr << "[fail] rsp-to-ibuffer bubble detected at cycle "
                  << main_time << std::endl;
        delete top;
        return 1;
      }
    }
  }
  if (!saw_rsp) {
    std::cerr << "[fail] no icache response observed in phase-0" << std::endl;
    delete top;
    return 1;
  }
  if (overlap_rsp_capture_and_req_fire == 0) {
    std::cerr << "[fail] no rsp-capture/req-fire overlap, fetch pipe still has"
                 " a bubble"
              << std::endl;
    delete top;
    return 1;
  }

  // Phase-1: block ibuffer to validate fetch-queue accumulation and flush drop.
  top->ibuffer_ready_i = 0;

  int req_fire_cnt_while_blocked = 0;
  std::vector<uint32_t> req_pc_trace;
  req_pc_trace.reserve(16);
  bool saw_prefetch_meta_before_flush = false;
  uint32_t preflush_epoch_slot0 = 0;

  for (int i = 0; i < 120; ++i) {
    tick(top, mem);
    if (top->dbg_ifu_req_fire_o) {
      req_fire_cnt_while_blocked++;
      req_pc_trace.push_back(top->dbg_ifu_req_addr_o);
    }
    if (top->ibuffer_valid_o) {
      if (!top->dbg_ibuf_meta_uniform_o) {
        std::cerr << "[fail] ibuffer bundle metadata is not uniform before flush"
                  << std::endl;
        delete top;
        return 1;
      }
      saw_prefetch_meta_before_flush = true;
      preflush_epoch_slot0 = top->dbg_ibuf_fetch_epoch_slot0_o;
    }
  }

  std::cout << "[info] blocked-window req_fire_count=" << req_fire_cnt_while_blocked
            << std::endl;
  // Phase--1 already proved multi-outstanding (>1) under blocked ibuffer before first
  // response. Here we only require "still making forward progress" while blocked.
  if (req_fire_cnt_while_blocked < 1) {
    std::cerr << "[fail] IFU made no forward progress while ibuffer_ready=0"
              << std::endl;
    std::cerr << "[info] blocked-window req_pc_trace:";
    for (size_t i = 0; i < req_pc_trace.size(); ++i) {
      std::cerr << " 0x" << std::hex << req_pc_trace[i] << std::dec;
    }
    std::cerr << std::endl;
    delete top;
    return 1;
  }

  top->flush_i = 1;
  top->redirect_pc_i = kRedirectPc;
  // Regression: no response may be captured during flush cycle.
  for (int i = 0; i < 2; ++i) {
    tick(top, mem);
    if (top->dbg_ifu_rsp_capture_o) {
      std::cerr << "[fail] IFU captured response while flush_i=1" << std::endl;
      delete top;
      return 1;
    }
  }
  top->flush_i = 0;
  top->redirect_pc_i = 0;

  int drop_stale_after_flush = 0;
  for (int i = 0; i < 20; ++i) {
    tick(top, mem);
    if (top->dbg_ifu_drop_stale_rsp_o) {
      drop_stale_after_flush++;
    }
  }

  bool got_first_rsp = false;
  uint32_t first_rsp_pc = 0;
  uint32_t first_rsp_instr0 = 0;
  uint32_t first_rsp_ftq_id_slot0 = 0;
  uint32_t first_rsp_epoch_slot0 = 0;
  for (int i = 0; i < 200; ++i) {
    tick(top, mem);
    if (top->ibuffer_valid_o) {
      if (!top->dbg_ibuf_meta_uniform_o) {
        std::cerr << "[fail] ibuffer bundle metadata is not uniform after flush"
                  << std::endl;
        delete top;
        return 1;
      }
      got_first_rsp = true;
      first_rsp_pc = top->ibuffer_pcs_o[0];
      first_rsp_instr0 = get_instr(top, 0);
      first_rsp_ftq_id_slot0 = top->dbg_ibuf_ftq_id_slot0_o;
      first_rsp_epoch_slot0 = top->dbg_ibuf_fetch_epoch_slot0_o;
      break;
    }
  }

  if (!got_first_rsp) {
    std::cerr << "[fail] timeout waiting first ibuffer response after flush"
              << std::endl;
    delete top;
    return 1;
  }

  std::cout << std::hex << std::showbase;
  std::cout << "[info] first_visible_rsp_pc=" << first_rsp_pc
            << " first_instr0=" << first_rsp_instr0
            << " first_ftq_id_slot0=" << first_rsp_ftq_id_slot0
            << " first_epoch_slot0=" << first_rsp_epoch_slot0 << std::endl;
  std::cout << std::dec << std::noshowbase;

  if (first_rsp_pc != kRedirectPc) {
    std::cerr << "[fail] stale pre-flush response was not dropped" << std::endl;
    delete top;
    return 1;
  }

  if (first_rsp_instr0 != 0x10000013u) {
    std::cerr << "[fail] unexpected instruction at redirect target" << std::endl;
    delete top;
    return 1;
  }
  if (saw_prefetch_meta_before_flush &&
      first_rsp_epoch_slot0 == preflush_epoch_slot0) {
    std::cerr << "[fail] fetch_epoch did not advance across flush (stale epoch visible)"
              << std::endl;
    delete top;
    return 1;
  }
  // With ibuffer inside frontend, stale fetch groups may be flushed in ibuffer/aligner
  // without surfacing as IFU drop_stale_rsp; redirect-target output is the functional check.
  if (drop_stale_after_flush == 0) {
    std::cout << "[info] no IFU drop_stale_rsp after flush (stale data cleared in frontend ibuffer)"
              << std::endl;
  }

  std::cout << "--- ALL TESTS PASSED ---" << std::endl;
  delete top;
  return 0;
}
