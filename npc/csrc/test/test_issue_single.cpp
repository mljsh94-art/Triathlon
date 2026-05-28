#include "Vtb_issue_single.h"
#include "verilated.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

static const int INSTR_PER_FETCH = 4;
static const int UOP_WORDS = 4;
static vluint64_t main_time = 0;

static void tick(Vtb_issue_single *top) {
  top->clk = 0;
  top->eval();
  main_time++;
  top->clk = 1;
  top->eval();
  main_time++;
}

struct DispatchInstr {
  bool valid;
  uint32_t op;
  uint32_t dst_tag;
  uint32_t v1;
  uint32_t q1;
  bool r1;
  uint32_t v2;
  uint32_t q2;
  bool r2;
};

static void set_dispatch(Vtb_issue_single *top, const std::vector<DispatchInstr> &instrs) {
  top->dispatch_valid = 0;
  top->dispatch_has_rs1 = 0;
  top->dispatch_has_rs2 = 0;
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    for (int w = 0; w < UOP_WORDS; ++w) {
      top->dispatch_op[i][w] = 0;
    }
    top->dispatch_dst[i] = 0;
    top->dispatch_v1[i] = 0;
    top->dispatch_q1[i] = 0;
    top->dispatch_r1[i] = 0;
    top->dispatch_v2[i] = 0;
    top->dispatch_q2[i] = 0;
    top->dispatch_r2[i] = 0;
  }

  uint8_t valid_mask = 0;
  for (size_t i = 0; i < instrs.size() && i < INSTR_PER_FETCH; ++i) {
    if (!instrs[i].valid) continue;
    valid_mask |= static_cast<uint8_t>(1u << i);
    top->dispatch_op[i][0] = instrs[i].op;
    top->dispatch_has_rs1 |= static_cast<uint8_t>(1u << i);
    top->dispatch_has_rs2 |= static_cast<uint8_t>(1u << i);
    top->dispatch_dst[i] = instrs[i].dst_tag;
    top->dispatch_v1[i] = instrs[i].v1;
    top->dispatch_q1[i] = instrs[i].q1;
    top->dispatch_r1[i] = instrs[i].r1;
    top->dispatch_v2[i] = instrs[i].v2;
    top->dispatch_q2[i] = instrs[i].q2;
    top->dispatch_r2[i] = instrs[i].r2;
  }
  top->dispatch_valid = valid_mask;
}

static void set_cdb(Vtb_issue_single *top,
                    const std::vector<std::pair<uint32_t, uint32_t>> &updates) {
  top->cdb_valid = 0;
  for (int i = 0; i < 4; ++i) {
    top->cdb_tag[i] = 0;
    top->cdb_val[i] = 0;
  }

  uint8_t valid_mask = 0;
  for (size_t i = 0; i < updates.size() && i < 4; ++i) {
    valid_mask |= static_cast<uint8_t>(1u << i);
    top->cdb_tag[i] = updates[i].first;
    top->cdb_val[i] = updates[i].second;
  }
  top->cdb_valid = valid_mask;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_issue_single *top = new Vtb_issue_single;

  std::cout << "--- [START] Issue-Single Verification ---" << std::endl;
  top->flush_i = 0;
  top->head_en_i = 0;
  top->head_tag_i = 0;
  top->cdb_wakeup_mask = 0xF;

  top->rst_n = 0;
  set_dispatch(top, {});
  set_cdb(top, {});
  tick(top);
  top->rst_n = 1;
  tick(top);

  const uint32_t OP_WAIT = 0x000000CC;
  const uint32_t DATA_12 = 0xDA7A0012;

  // 1) Dispatch an instruction waiting on q1=12.
  set_dispatch(top, {{true, OP_WAIT, 17, 0, 12, false, 0x12345678u, 0, true}});
  tick(top);
  set_dispatch(top, {});

  // 2) Same-cycle CDB wakeup should make it immediately issuable.
  set_cdb(top, {{12, DATA_12}});
  top->eval();

  bool same_cycle_issue = (top->fu_en && top->fu_uop[0] == OP_WAIT);
  assert(same_cycle_issue && "issue_single should issue in same cycle as matching CDB wakeup");
  assert(top->fu_v1 == DATA_12 && "issue_single should forward same-cycle CDB value to fu_v1");

  tick(top);
  set_cdb(top, {});

  std::cout << "--- [SUCCESS] Issue-Single Tests Passed ---" << std::endl;
  delete top;
  return 0;
}
