#include "Vtb_bundle_fifo.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

static vluint64_t main_time = 0;

static void tick(Vtb_bundle_fifo* top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

static void reset(Vtb_bundle_fifo* top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->enq_valid_i = 0;
  top->enq_data_i = 0;
  top->deq_ready_i = 0;
  tick(top);
  tick(top);
  top->rst_ni = 1;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_bundle_fifo* top = new Vtb_bundle_fifo;

  reset(top);

  // Case 1: bypass on empty queue
  top->enq_valid_i = 1;
  top->enq_data_i = 0x12345678u;
  top->deq_ready_i = 1;
  top->eval();
  if (!top->deq_valid_o || top->deq_data_o != 0x12345678u || top->dbg_count_o != 0) {
    std::cerr << "[fail] bypass behavior mismatch" << std::endl;
    delete top;
    return 1;
  }
  tick(top);

  // Case 2: enqueue while downstream blocked
  top->enq_valid_i = 1;
  top->enq_data_i = 0x11111111u;
  top->deq_ready_i = 0;
  tick(top);
  top->enq_data_i = 0x22222222u;
  tick(top);

  if (top->dbg_count_o != 2) {
    std::cerr << "[fail] expected count=2 after blocking enqueue" << std::endl;
    delete top;
    return 1;
  }

  // Case 3: pop in order
  top->enq_valid_i = 0;
  top->deq_ready_i = 1;
  top->eval();
  if (!top->deq_valid_o || top->deq_data_o != 0x11111111u) {
    std::cerr << "[fail] first pop mismatch" << std::endl;
    delete top;
    return 1;
  }
  tick(top);
  top->eval();
  if (!top->deq_valid_o || top->deq_data_o != 0x22222222u) {
    std::cerr << "[fail] second pop mismatch" << std::endl;
    delete top;
    return 1;
  }
  tick(top);

  // Case 4: flush clears fifo
  top->enq_valid_i = 1;
  top->deq_ready_i = 0;
  top->enq_data_i = 0xabcdef01u;
  tick(top);
  top->flush_i = 1;
  tick(top);
  top->flush_i = 0;
  top->enq_valid_i = 0;
  top->deq_ready_i = 1;
  top->eval();
  if (top->deq_valid_o || top->dbg_count_o != 0 || !top->dbg_empty_o) {
    std::cerr << "[fail] flush should clear queue" << std::endl;
    delete top;
    return 1;
  }

  std::cout << "--- ALL TESTS PASSED ---" << std::endl;
  delete top;
  return 0;
}
