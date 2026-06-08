// test_ftq.cpp — C++ Verilator driver for FTQ FIFO verification
// Verification points:
//   1. Basic FIFO: enq/deq order correct, full/empty correct
//   2. Flush: count resets to zero, enq immediately available
//   3. Simultaneous enq+deq: count unchanged
//   4. Pointer wrap-around
//   5. deq_ftq_id_o tracks head pointer

#include "Vtb_ftq.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t sim_time = 0;
static int pass_count = 0;
static int fail_count = 0;

static constexpr int DEPTH = 4;

static void tick(Vtb_ftq* top) {
  top->clk_i = 0;
  top->eval();
  sim_time++;
  top->clk_i = 1;
  top->eval();
  sim_time++;
}

static void reset(Vtb_ftq* top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->enq_valid_i = 0;
  top->deq_ready_i = 0;
  top->enq_pc_i = 0;
  top->enq_pred_slot_valid_i = 0;
  top->enq_pred_slot_idx_i = 0;
  top->enq_pred_target_i = 0;
  top->enq_pred_npc_i = 0;
  top->enq_epoch_i = 0;
  tick(top);
  tick(top);
  top->rst_ni = 1;
  tick(top);
}

static void check(const char* msg, bool cond) {
  if (cond) {
    pass_count++;
  } else {
    fail_count++;
    printf("[FAIL] %s\n", msg);
  }
}

// Enqueue one entry: set signals, tick once, then deassert valid
static void enqueue(Vtb_ftq* top, uint32_t pc, int pred_sv, int pred_si,
                    uint32_t pred_tgt, uint32_t pred_npc, int epoch) {
  top->enq_valid_i = 1;
  top->enq_pc_i = pc;
  top->enq_pred_slot_valid_i = pred_sv;
  top->enq_pred_slot_idx_i = pred_si;
  top->enq_pred_target_i = pred_tgt;
  top->enq_pred_npc_i = pred_npc;
  top->enq_epoch_i = epoch;
  tick(top);
  top->enq_valid_i = 0;
}

// Dequeue one entry: assert deq_ready, tick, deassert
static void dequeue(Vtb_ftq* top) {
  top->deq_ready_i = 1;
  tick(top);
  top->deq_ready_i = 0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ftq* top = new Vtb_ftq;

  reset(top);

  // ============================
  // Test 1: Empty after reset
  // ============================
  printf("\n=== Test 1: Empty after reset ===\n");
  top->eval();
  check("count == 0 after reset", top->count_o == 0);
  check("enq_ready == 1 after reset", top->enq_ready_o == 1);
  check("deq_valid == 0 after reset (empty)", top->deq_valid_o == 0);

  // ============================
  // Test 2: Enqueue to full
  // ============================
  printf("\n=== Test 2: Enqueue to full ===\n");
  for (int i = 0; i < DEPTH; i++) {
    enqueue(top, 0x80000000 + i * 8, (i % 2 == 0) ? 1 : 0, i % 2,
            0x90000000 + i * 4, 0x80000000 + (i + 1) * 8, i);
  }
  top->eval();
  check("count == DEPTH after filling", top->count_o == DEPTH);
  check("enq_ready == 0 when full", top->enq_ready_o == 0);
  check("deq_valid == 1 when not empty", top->deq_valid_o == 1);

  // ============================
  // Test 3: Dequeue in FIFO order
  // ============================
  printf("\n=== Test 3: Dequeue in FIFO order ===\n");
  for (int i = 0; i < DEPTH; i++) {
    // Check head data BEFORE consuming
    top->eval();
    char buf[256];

    snprintf(buf, sizeof(buf), "deq_pc[%d] = 0x%08x (expected 0x%08x)",
             i, top->deq_pc_o, 0x80000000u + i * 8);
    check(buf, top->deq_pc_o == (0x80000000u + i * 8));

    snprintf(buf, sizeof(buf), "deq_pred_slot_valid[%d] = %d (expected %d)",
             i, top->deq_pred_slot_valid_o, (i % 2 == 0) ? 1 : 0);
    check(buf, top->deq_pred_slot_valid_o == ((i % 2 == 0) ? 1 : 0));

    snprintf(buf, sizeof(buf), "deq_pred_npc[%d] = 0x%08x (expected 0x%08x)",
             i, top->deq_pred_npc_o, 0x80000000u + (i + 1) * 8);
    check(buf, top->deq_pred_npc_o == (0x80000000u + (i + 1) * 8));

    snprintf(buf, sizeof(buf), "deq_epoch[%d] = %d (expected %d)",
             i, top->deq_epoch_o, i);
    check(buf, top->deq_epoch_o == (i & 0x7));

    snprintf(buf, sizeof(buf), "deq_ftq_id[%d] = %d (head ptr)", i, top->deq_ftq_id_o);
    check(buf, top->deq_ftq_id_o == (i % DEPTH));

    dequeue(top);
  }
  top->eval();
  check("count == 0 after draining", top->count_o == 0);
  check("deq_valid == 0 after draining", top->deq_valid_o == 0);
  check("enq_ready == 1 after draining", top->enq_ready_o == 1);

  // ============================
  // Test 4: Flush clears all, count resets
  // ============================
  printf("\n=== Test 4: Flush behavior ===\n");
  enqueue(top, 0xAAAA0000, 1, 0, 0xBBBB0000, 0xAAAA0008, 1);
  enqueue(top, 0xAAAA0008, 0, 1, 0xBBBB0008, 0xAAAA0010, 1);
  top->eval();
  check("count == 2 before flush", top->count_o == 2);

  // Assert flush for one cycle
  top->flush_i = 1;
  tick(top);
  top->flush_i = 0;
  top->eval();

  check("count == 0 after flush", top->count_o == 0);
  check("deq_valid == 0 after flush", top->deq_valid_o == 0);
  check("enq_ready == 1 after flush", top->enq_ready_o == 1);

  // Enqueue immediately after flush
  enqueue(top, 0xCCCC0000, 1, 0, 0xDDDD0000, 0xCCCC0008, 2);
  top->eval();
  check("count == 1 after post-flush enq", top->count_o == 1);
  check("deq_pc == 0xCCCC0000 after post-flush enq", top->deq_pc_o == 0xCCCC0000u);
  check("deq_pred_npc == 0xCCCC0008 after post-flush enq", top->deq_pred_npc_o == 0xCCCC0008u);

  // Drain
  dequeue(top);

  // ============================
  // Test 5: Simultaneous enq + deq
  // ============================
  printf("\n=== Test 5: Simultaneous enq + deq ===\n");
  // Enqueue 2 entries
  enqueue(top, 0x10000000, 0, 0, 0x20000000, 0x10000008, 0);
  enqueue(top, 0x10000008, 1, 1, 0x20000008, 0x10000010, 0);
  top->eval();
  check("count == 2 before simultaneous", top->count_o == 2);

  // Simultaneous enq + deq
  top->enq_valid_i = 1;
  top->enq_pc_i = 0x10000010;
  top->enq_pred_slot_valid_i = 0;
  top->enq_pred_slot_idx_i = 0;
  top->enq_pred_target_i = 0x20000010;
  top->enq_pred_npc_i = 0x10000018;
  top->enq_epoch_i = 0;
  top->deq_ready_i = 1;
  tick(top);
  top->enq_valid_i = 0;
  top->deq_ready_i = 0;
  top->eval();
  check("count == 2 after simultaneous enq+deq (unchanged)", top->count_o == 2);

  // Drain
  top->deq_ready_i = 1;
  tick(top);
  tick(top);
  top->deq_ready_i = 0;
  top->eval();

  // ============================
  // Test 6: Pointer wrap-around
  // ============================
  printf("\n=== Test 6: Pointer wrap-around ===\n");
  // At this point head and tail pointers have advanced.
  // Do 2 full rounds of enqueue+dequeue to force wrap-around.
  for (int round = 0; round < 2; round++) {
    for (int i = 0; i < DEPTH; i++) {
      uint32_t pc = 0xF0000000u + (round * DEPTH + i) * 4;
      enqueue(top, pc, 0, 0, 0, pc + 4, round);
    }
    top->eval();
    check("full after wrap-around fill", top->count_o == DEPTH);

    for (int i = 0; i < DEPTH; i++) {
      top->eval();
      uint32_t expected_pc = 0xF0000000u + (round * DEPTH + i) * 4;
      char buf[256];
      snprintf(buf, sizeof(buf), "wrap round=%d i=%d deq_pc=0x%08x (expected 0x%08x)",
               round, i, top->deq_pc_o, expected_pc);
      check(buf, top->deq_pc_o == expected_pc);
      dequeue(top);
    }
    top->eval();
    check("empty after wrap-around drain", top->count_o == 0);
  }

  // ============================
  // Test 7: enq_ready blocked during flush
  // ============================
  printf("\n=== Test 7: enq_ready blocked during flush cycle ===\n");
  // During the flush cycle itself, enq_ready should be 0
  enqueue(top, 0x11110000, 0, 0, 0, 0x11110004, 0);
  top->flush_i = 1;
  top->eval();
  check("enq_ready == 0 during flush assertion", top->enq_ready_o == 0);
  check("deq_valid == 0 during flush assertion", top->deq_valid_o == 0);
  tick(top);
  top->flush_i = 0;
  top->eval();
  check("enq_ready == 1 after flush deasserted", top->enq_ready_o == 1);

  // ============================
  // Summary
  // ============================
  printf("\n========================================\n");
  printf("  FTQ FIFO Testbench Results\n");
  printf("  PASS: %d  FAIL: %d\n", pass_count, fail_count);
  printf("========================================\n");
  if (fail_count > 0) {
    printf("[RESULT] SOME TESTS FAILED!\n");
    delete top;
    return 1;
  } else {
    printf("[RESULT] ALL TESTS PASSED!\n");
    printf("--- ALL TESTS PASSED ---\n");
    delete top;
    return 0;
  }
}
