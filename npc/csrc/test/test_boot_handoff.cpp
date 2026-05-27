#include "Vtb_boot_handoff.h"
#include "../include/boot_loader.h"
#include "../include/memory_models.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kLoopInsn = 0x0000006fu;  // jal x0, 0
constexpr int kCommitWidth = 4;

uint32_t enc_i(uint32_t imm12, uint32_t rs1, uint32_t funct3, uint32_t rd, uint32_t opcode) {
  return ((imm12 & 0xfffu) << 20) | ((rs1 & 0x1fu) << 15) | ((funct3 & 0x7u) << 12) |
         ((rd & 0x1fu) << 7) | (opcode & 0x7fu);
}

uint32_t insn_addi(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(static_cast<uint32_t>(imm), rs1, 0x0u, rd, 0x13u);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Vtb_boot_handoff top;
  npc::MemSystem mem;
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;
  vluint64_t sim_time = 0;

  const npc::BootHandoff handoff = npc::make_default_boot_handoff();
  const uint32_t opensbi_entry = npc::kPmemBase + 0x200u;

  // Boot ROM stub at reset vector (0x1000) transfers control to OpenSBI.
  npc::install_boot_handoff_stub(mem.mem, opensbi_entry, handoff, npc::kBootRomBase);
  const uint32_t bootrom_word_before = mem.mem.read_word(npc::kBootRomBase);

  // Boot ROM must be read-only for runtime stores.
  mem.mem.write_store(npc::kBootRomBase, 0xaabbccddu, 7u);  // sb
  mem.mem.write_store(npc::kBootRomBase, 0x00001122u, 8u);  // sh
  mem.mem.write_store(npc::kBootRomBase, 0x55667788u, 9u);  // sw
  const uint32_t bootrom_word_after = mem.mem.read_word(npc::kBootRomBase);
  if (bootrom_word_after != bootrom_word_before) {
    std::cerr << "[FAIL] bootrom writable by store path: before=0x" << std::hex
              << bootrom_word_before << " after=0x" << bootrom_word_after
              << std::dec << "\n";
    return 1;
  }

  // OpenSBI entry stub: capture a0/a1 into x12/x13 then stop.
  mem.mem.write_word(opensbi_entry + 0x00u, insn_addi(12, 10, 0));
  mem.mem.write_word(opensbi_entry + 0x04u, insn_addi(13, 11, 0));
  mem.mem.write_word(opensbi_entry + 0x08u, kLoopInsn);

  npc::reset(&top, mem, nullptr, sim_time);

  bool entered_opensbi = false;
  bool saw_bootrom_commit = false;
  uint32_t seen_a0 = 0xdeadbeefu;
  uint32_t seen_a1 = 0xdeadbeefu;

  for (uint64_t cycle = 0; cycle < 4000; cycle++) {
    mem.mem.set_time_us(cycle);
    npc::tick(&top, mem, nullptr, sim_time);

    for (int i = 0; i < kCommitWidth; i++) {
      if (((top.commit_valid_o >> i) & 0x1) == 0) continue;
      uint32_t pc = top.commit_pc_o[i];
      uint32_t inst = top.commit_decoded_inst_o[i];
      bool we = ((top.commit_we_o >> i) & 0x1) != 0;
      uint32_t rd = (top.commit_areg_o >> (i * 5)) & 0x1fu;
      uint32_t wdata = top.commit_wdata_o[i];

      if (we && rd == 12) seen_a0 = wdata;
      if (we && rd == 13) seen_a1 = wdata;
      if (pc == npc::kBootRomBase) saw_bootrom_commit = true;
      if (pc == opensbi_entry) entered_opensbi = true;

      if (inst == kLoopInsn && pc == opensbi_entry + 0x08u) {
        if (!saw_bootrom_commit || !entered_opensbi ||
            seen_a0 != handoff.hartid || seen_a1 != handoff.dtb_addr) {
          std::cerr << "[FAIL] boot handoff mismatch: entered=" << entered_opensbi
                    << " saw_bootrom=" << saw_bootrom_commit
                    << " a0=0x" << std::hex << seen_a0
                    << " a1=0x" << seen_a1
                    << " expected_a0=0x" << handoff.hartid
                    << " expected_a1=0x" << handoff.dtb_addr
                    << std::dec << "\n";
          return 1;
        }
        std::cout << "[PASS] test_boot_handoff" << std::endl;
        return 0;
      }
    }
  }

  std::cerr << "[FAIL] timed out waiting for boot handoff completion\n";
  return 1;
}
