#include "Vtb_ftq.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

static vluint64_t main_time = 0;

static void tick(Vtb_ftq *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

static void reset(Vtb_ftq *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->enq_valid_i = 0;
  top->enq_pc_i = 0;
  top->enq_pred_slot_valid_i = 0;
  top->enq_pred_slot_idx_i = 0;
  top->enq_pred_target_i = 0;
  top->enq_pred_npc_i = 0;
  top->enq_epoch_i = 0;
  top->deq_ready_i = 0;
  tick(top);
  tick(top);
  top->rst_ni = 1;
}

static bool enqueue_pc(Vtb_ftq *top, uint32_t pc, uint32_t npc) {
  top->enq_valid_i = 1;
  top->enq_pc_i = pc;
  top->enq_pred_npc_i = npc;
  top->enq_pred_slot_valid_i = 0;
  top->enq_pred_slot_idx_i = 0;
  top->enq_pred_target_i = 0;
  top->enq_epoch_i = 0;
  top->deq_ready_i = 0;
  top->eval();
  if (!top->enq_ready_o) {
    return false;
  }
  tick(top);
  return true;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ftq *top = new Vtb_ftq;

  reset(top);

  if (!top->dbg_empty_o || top->dbg_count_o != 0 || top->deq_valid_o) {
    std::cerr << "[fail] reset should leave FTQ empty" << std::endl;
    delete top;
    return 1;
  }

  // Case 1: FIFO enqueue/dequeue order
  for (int i = 0; i < 3; i++) {
    uint32_t pc = 0x80000000u + static_cast<uint32_t>(i * 16);
    if (!enqueue_pc(top, pc, pc + 16)) {
      std::cerr << "[fail] enqueue #" << i << " blocked unexpectedly" << std::endl;
      delete top;
      return 1;
    }
  }
  top->enq_valid_i = 0;

  if (top->dbg_count_o != 3) {
    std::cerr << "[fail] expected count=3 after three enqueues" << std::endl;
    delete top;
    return 1;
  }

  for (int i = 0; i < 3; i++) {
    uint32_t expect_pc = 0x80000000u + static_cast<uint32_t>(i * 16);
    top->deq_ready_i = 1;
    top->eval();
    if (!top->deq_valid_o) {
      std::cerr << "[fail] dequeue #" << i << " not valid" << std::endl;
      delete top;
      return 1;
    }
    if (top->deq_pc_o != expect_pc) {
      std::cerr << "[fail] dequeue #" << i << " pc mismatch" << std::endl;
      delete top;
      return 1;
    }
    if (top->deq_ftq_id_o != static_cast<uint32_t>(i)) {
      std::cerr << "[fail] dequeue #" << i << " ftq_id mismatch" << std::endl;
      delete top;
      return 1;
    }
    tick(top);
  }

  if (!top->dbg_empty_o || top->dbg_count_o != 0) {
    std::cerr << "[fail] queue should be empty after draining" << std::endl;
    delete top;
    return 1;
  }

  // Case 2: full blocks further enqueue
  reset(top);
  for (int i = 0; i < 4; i++) {
    uint32_t pc = 0x80001000u + static_cast<uint32_t>(i * 16);
    if (!enqueue_pc(top, pc, pc + 16)) {
      std::cerr << "[fail] fill enqueue #" << i << " blocked early" << std::endl;
      delete top;
      return 1;
    }
  }
  if (!top->dbg_full_o || top->dbg_count_o != 4) {
    std::cerr << "[fail] expected full queue with count=4" << std::endl;
    delete top;
    return 1;
  }

  top->enq_pc_i = 0xdeadbeefu;
  top->enq_valid_i = 1;
  top->eval();
  if (top->enq_ready_o) {
    std::cerr << "[fail] enqueue should backpressure when full" << std::endl;
    delete top;
    return 1;
  }
  top->enq_valid_i = 0;
  tick(top);

  // Case 3: flush clears queue
  top->flush_i = 1;
  tick(top);
  top->flush_i = 0;
  top->deq_ready_i = 1;
  top->eval();
  if (top->deq_valid_o || !top->dbg_empty_o || top->dbg_count_o != 0) {
    std::cerr << "[fail] flush should clear queue" << std::endl;
    delete top;
    return 1;
  }

  std::cout << "--- ALL TESTS PASSED ---" << std::endl;
  delete top;
  return 0;
}
