// csrc/test/test_ibuffer.cpp
#include "Vtb_ibuffer.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <random>
#include <vector>

const int INSTR_PER_FETCH = 4;
const int DECODE_WIDTH = 4;
const int FE_EXPAND_MAX = 8;
const int IB_DEPTH = 8;
const int ILEN_BYTES = 4;

vluint64_t main_time = 0;

struct Instruction {
  uint32_t inst;
  uint32_t raw_inst;
  uint32_t pc;
  uint8_t slot_valid;
  uint32_t pred_npc;
  uint8_t is_rvc;
};

void tick(Vtb_ibuffer *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

void reset(Vtb_ibuffer *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->aln_valid_i = 0;
  top->ibuf_ready_i = 0;
  top->aln_entry_count_i = 0;
  top->aln_slot_valid_i = 0;
  top->aln_is_rvc_i = 0;
  for (int i = 0; i < FE_EXPAND_MAX; ++i) {
    top->aln_instrs_i[i] = 0;
    top->aln_raw_instrs_i[i] = 0;
    top->aln_pcs_i[i] = 0;
    top->aln_pred_npc_i[i] = 0;
  }
  tick(top);
  tick(top);
  top->rst_ni = 1;
}

void push_aligned_entries(Vtb_ibuffer *top, const std::vector<Instruction> &entries) {
  assert(entries.size() <= FE_EXPAND_MAX);
  top->aln_entry_count_i = static_cast<uint32_t>(entries.size());
  top->aln_slot_valid_i = 0;
  top->aln_is_rvc_i = 0;
  for (int i = 0; i < FE_EXPAND_MAX; ++i) {
    if (i < static_cast<int>(entries.size())) {
      top->aln_instrs_i[i] = entries[i].inst;
      top->aln_raw_instrs_i[i] = entries[i].raw_inst;
      top->aln_pcs_i[i] = entries[i].pc;
      top->aln_pred_npc_i[i] = entries[i].pred_npc;
      top->aln_slot_valid_i |= (1u << i);
      if (entries[i].is_rvc) top->aln_is_rvc_i |= (1u << i);
    } else {
      top->aln_instrs_i[i] = 0;
      top->aln_raw_instrs_i[i] = 0;
      top->aln_pcs_i[i] = 0;
      top->aln_pred_npc_i[i] = 0;
    }
  }
}

std::vector<Instruction> get_decode_group(Vtb_ibuffer *top) {
  std::vector<Instruction> group;
  for (int i = 0; i < DECODE_WIDTH; ++i) {
    Instruction instr;
    instr.inst = top->ibuf_instrs_o[i];
    instr.raw_inst = top->ibuf_raw_instrs_o[i];
    instr.pc = top->ibuf_pcs_o[i];
    instr.slot_valid = (top->ibuf_slot_valid_o >> i) & 0x1;
    instr.pred_npc = top->ibuf_pred_npc_o[i];
    instr.is_rvc = (top->ibuf_is_rvc_o >> i) & 0x1;
    group.push_back(instr);
  }
  return group;
}

static Instruction make_rv32(uint32_t inst, uint32_t pc) {
  Instruction e{};
  e.inst = inst;
  e.raw_inst = inst;
  e.pc = pc;
  e.slot_valid = 1;
  e.pred_npc = pc + 4;
  e.is_rvc = 0;
  return e;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ibuffer *top = new Vtb_ibuffer;

  std::cout << "--- [START] IBuffer FIFO Verification ---" << std::endl;
  reset(top);

  // Case 1: empty bypass
  {
    const uint32_t base_pc = 0x80001000;
    std::vector<Instruction> entries = {
        make_rv32(0x11111113, base_pc),
        make_rv32(0x22222223, base_pc + 4),
    };
    top->flush_i = 0;
    top->aln_valid_i = 1;
    top->ibuf_ready_i = 1;
    push_aligned_entries(top, entries);
    top->clk_i = 0;
    top->eval();

    if (!top->aln_ready_o) {
      std::cerr << "[fail] expected aln ready for empty bypass case" << std::endl;
      return 1;
    }
    if (!top->ibuf_valid_o) {
      std::cerr << "[fail] expected same-cycle ibuf_valid in empty bypass case" << std::endl;
      return 1;
    }
    if (top->ibuf_instrs_o[0] != entries[0].inst || top->ibuf_pcs_o[0] != base_pc ||
        top->ibuf_slot_valid_o != 0b0011) {
      std::cerr << "[fail] bypass output mismatch" << std::endl;
      return 1;
    }
    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  // Case 2: elastic merge (2 queued + 2 new => 4)
  {
    reset(top);
    const uint32_t old_pc = 0x80002000;
    const uint32_t new_pc = 0x80003000;
    std::vector<Instruction> old_entries = {
        make_rv32(0xaaaa0013, old_pc),
        make_rv32(0xaaaa0023, old_pc + 4),
    };
    std::vector<Instruction> new_entries = {
        make_rv32(0xbbbb0013, new_pc),
        make_rv32(0xbbbb0023, new_pc + 4),
    };

    top->aln_valid_i = 1;
    top->ibuf_ready_i = 0;
    push_aligned_entries(top, old_entries);
    top->clk_i = 0;
    top->eval();
    if (!top->aln_ready_o) {
      std::cerr << "[fail] expected aln ready when enqueueing partial bundle" << std::endl;
      return 1;
    }
    top->clk_i = 1;
    top->eval();
    main_time++;

    top->aln_valid_i = 1;
    top->ibuf_ready_i = 1;
    push_aligned_entries(top, new_entries);
    top->clk_i = 0;
    top->eval();

    if (!top->ibuf_valid_o || top->ibuf_slot_valid_o != 0b1111) {
      std::cerr << "[fail] elastic merge slot_valid mismatch" << std::endl;
      return 1;
    }
    if (top->ibuf_instrs_o[0] != old_entries[0].inst ||
        top->ibuf_instrs_o[1] != old_entries[1].inst ||
        top->ibuf_instrs_o[2] != new_entries[0].inst ||
        top->ibuf_instrs_o[3] != new_entries[1].inst) {
      std::cerr << "[fail] elastic merge lane content mismatch" << std::endl;
      return 1;
    }
    top->clk_i = 1;
    top->eval();
    main_time++;
  }

  std::cout << "--- [PASSED] IBuffer FIFO verification successful! ---" << std::endl;
  delete top;
  return 0;
}
