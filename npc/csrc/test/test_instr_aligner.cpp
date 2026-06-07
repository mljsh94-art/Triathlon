// csrc/test/test_instr_aligner.cpp
#include "Vtb_instr_aligner.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <vector>

const int INSTR_PER_FETCH = 4;
const int FE_EXPAND_MAX = 8;
const int ILEN_BYTES = 4;

vluint64_t main_time = 0;

void tick(Vtb_instr_aligner *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

void reset(Vtb_instr_aligner *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->fe_valid_i = 0;
  top->ibuf_aln_ready_i = 1;
  top->fe_slot_valid_i = 0;
  top->fe_pc_i = 0;
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    top->fe_instrs_i[i] = 0;
    top->fe_pred_npc_i[i] = 0;
  }
  tick(top);
  tick(top);
  top->rst_ni = 1;
}

void set_fetch_group_mask(Vtb_instr_aligner *top, uint32_t base_pc,
                          const std::vector<uint32_t> &instrs,
                          uint8_t slot_valid_mask) {
  assert(instrs.size() == INSTR_PER_FETCH);
  top->fe_pc_i = base_pc;
  top->fe_slot_valid_i = slot_valid_mask;
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    top->fe_instrs_i[i] = instrs[i];
    top->fe_pred_npc_i[i] = base_pc + (i + 1) * ILEN_BYTES;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_instr_aligner *top = new Vtb_instr_aligner;

  std::cout << "--- [START] InstrAligner Verification ---" << std::endl;
  reset(top);

  // Case 3: RVC expansion (two c.nop in one word slot)
  {
    const uint32_t base_pc = 0x80004000;
    const std::vector<uint32_t> instrs = {0x00010001, 0, 0, 0};
    top->fe_valid_i = 1;
    top->ibuf_aln_ready_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0001);
    top->clk_i = 0;
    top->eval();

    if (top->aln_entry_count_o != 2) {
      std::cerr << "[fail] expected 2 aligned entries, got " << top->aln_entry_count_o
                << std::endl;
      return 1;
    }
    if (top->aln_slot_valid_o != 0b0011) {
      std::cerr << "[fail] expected two expanded slots" << std::endl;
      return 1;
    }
    if (top->aln_instrs_o[0] != 0x00000013 || top->aln_instrs_o[1] != 0x00000013) {
      std::cerr << "[fail] rvc expansion opcode mismatch" << std::endl;
      return 1;
    }
    if (top->aln_pcs_o[0] != base_pc || top->aln_pcs_o[1] != base_pc + 2) {
      std::cerr << "[fail] rvc expansion pc mismatch" << std::endl;
      return 1;
    }
    if (top->aln_pred_npc_o[0] != base_pc + 2 || top->aln_pred_npc_o[1] != base_pc + 4) {
      std::cerr << "[fail] rvc expansion pred_npc mismatch" << std::endl;
      return 1;
    }
    if (((top->aln_is_rvc_o >> 0) & 1) == 0 || ((top->aln_is_rvc_o >> 1) & 1) == 0) {
      std::cerr << "[fail] expected is_rvc set for compressed slots" << std::endl;
      return 1;
    }
    tick(top);
  }

  // Case 4: mixed 16/32 stream
  {
    reset(top);
    const uint32_t base_pc = 0x80005020;
    const std::vector<uint32_t> instrs = {
        0x00930001,
        0x011300c0,
        0x00010010,
        0x00000000,
    };
    top->fe_valid_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0111);
    top->clk_i = 0;
    top->eval();

    if (top->aln_entry_count_o != 4) {
      std::cerr << "[fail] expected 4 aligned entries in mixed rvc/rv32 case" << std::endl;
      return 1;
    }

    const uint32_t kExpInstr[4] = {0x00000013, 0x00c00093, 0x00100113, 0x00000013};
    const uint32_t kExpPc[4] = {base_pc + 0, base_pc + 2, base_pc + 6, base_pc + 10};
    const uint32_t kExpPredNpc[4] = {base_pc + 2, base_pc + 6, base_pc + 10, base_pc + 12};
    for (int i = 0; i < 4; ++i) {
      if (top->aln_instrs_o[i] != kExpInstr[i]) {
        std::cerr << "[fail] mixed rvc/rv32 inst mismatch at lane " << i << std::endl;
        return 1;
      }
      if (top->aln_pcs_o[i] != kExpPc[i]) {
        std::cerr << "[fail] mixed rvc/rv32 pc mismatch at lane " << i << std::endl;
        return 1;
      }
      if (top->aln_pred_npc_o[i] != kExpPredNpc[i]) {
        std::cerr << "[fail] mixed rvc/rv32 pred_npc mismatch at lane " << i << std::endl;
        return 1;
      }
    }
    tick(top);
  }

  // Case 5: non-NOP compressed control path
  {
    reset(top);
    const uint32_t base_pc = 0x80006000;
    const std::vector<uint32_t> instrs = {0x90028082, 0, 0, 0};
    top->fe_valid_i = 1;
    set_fetch_group_mask(top, base_pc, instrs, 0b0001);
    top->clk_i = 0;
    top->eval();

    if (top->aln_entry_count_o != 2) {
      std::cerr << "[fail] expected two expanded slots in rvc control case" << std::endl;
      return 1;
    }
    if (top->aln_instrs_o[0] != 0x00008067 || top->aln_instrs_o[1] != 0x00100073) {
      std::cerr << "[fail] rvc control expansion opcode mismatch" << std::endl;
      return 1;
    }
    tick(top);
  }

  std::cout << "--- [PASSED] InstrAligner verification successful! ---" << std::endl;
  delete top;
  return 0;
}
