#include "Vtb_plic.h"
#include "../include/memory_models.h"
#include "verilated.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kTrapVector = 0x80000120u;
constexpr uint32_t kExtMcause = 0x8000000bu;

uint32_t enc_i(uint32_t imm12, uint32_t rs1, uint32_t funct3, uint32_t rd, uint32_t opcode) {
  return ((imm12 & 0xfffu) << 20) | ((rs1 & 0x1fu) << 15) | ((funct3 & 0x7u) << 12) |
         ((rd & 0x1fu) << 7) | (opcode & 0x7fu);
}

uint32_t enc_u(uint32_t imm31_12, uint32_t rd, uint32_t opcode) {
  return ((imm31_12 & 0xfffffu) << 12) | ((rd & 0x1fu) << 7) | (opcode & 0x7fu);
}

uint32_t enc_b(int32_t imm, uint32_t rs2, uint32_t rs1, uint32_t funct3, uint32_t opcode) {
  uint32_t imm13 = static_cast<uint32_t>(imm) & 0x1fffu;
  uint32_t bit12 = (imm13 >> 12) & 0x1u;
  uint32_t bit11 = (imm13 >> 11) & 0x1u;
  uint32_t bits10_5 = (imm13 >> 5) & 0x3fu;
  uint32_t bits4_1 = (imm13 >> 1) & 0xfu;
  return (bit12 << 31) | (bits10_5 << 25) | ((rs2 & 0x1fu) << 20) | ((rs1 & 0x1fu) << 15) |
         ((funct3 & 0x7u) << 12) | (bits4_1 << 8) | (bit11 << 7) | (opcode & 0x7fu);
}

uint32_t insn_lui(uint32_t rd, uint32_t imm31_12) { return enc_u(imm31_12, rd, 0x37u); }
uint32_t insn_addi(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(static_cast<uint32_t>(imm), rs1, 0x0u, rd, 0x13u);
}
uint32_t insn_srli(uint32_t rd, uint32_t rs1, uint32_t shamt) {
  return enc_i(shamt & 0x1fu, rs1, 0x5u, rd, 0x13u);
}
uint32_t insn_csrrw(uint32_t rd, uint32_t rs1, uint32_t csr) {
  return enc_i(csr, rs1, 0x1u, rd, 0x73u);
}
uint32_t insn_csrrs(uint32_t rd, uint32_t rs1, uint32_t csr) {
  return enc_i(csr, rs1, 0x2u, rd, 0x73u);
}
uint32_t insn_beq(uint32_t rs1, uint32_t rs2, int32_t imm) {
  return enc_b(imm, rs2, rs1, 0x0u, 0x63u);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Vtb_plic top;
  npc::MemSystem mem;
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;
  vluint64_t sim_time = 0;

  const uint32_t base = npc::kPmemBase;

  // mtvec <- 0x80000120, mie.MEIE <- 1, mstatus.MIE <- 1, then spin.
  mem.mem.write_word(base + 0x00, insn_lui(1, 0x80000));    // x1 = 0x80000000
  mem.mem.write_word(base + 0x04, insn_addi(1, 1, 0x120));  // x1 = 0x80000120
  mem.mem.write_word(base + 0x08, insn_csrrw(0, 1, 0x305)); // csrw mtvec, x1
  mem.mem.write_word(base + 0x0c, insn_lui(2, 0x1));        // x2 = 0x00001000
  mem.mem.write_word(base + 0x10, insn_srli(2, 2, 1));      // x2 = 0x00000800 (MEIE)
  mem.mem.write_word(base + 0x14, insn_csrrw(0, 2, 0x304)); // csrw mie, x2
  mem.mem.write_word(base + 0x18, insn_addi(3, 0, 0x08));   // x3 = MIE bit
  mem.mem.write_word(base + 0x1c, insn_csrrs(0, 3, 0x300)); // csrs mstatus, x3
  mem.mem.write_word(base + 0x20, 0x00000013u);             // nop
  mem.mem.write_word(base + 0x24, insn_beq(0, 0, -4));      // spin (0x24 <-> 0x20)

  mem.mem.write_word(kTrapVector + 0x00, 0x00000013u);

  // Configure minimal PLIC state for source 1 -> M context.
  mem.mem.write_word(npc::kPlicPriority1, 1u);
  mem.mem.write_word(npc::kPlicEnableM, (1u << 1));
  mem.mem.write_word(npc::kPlicThresholdM, 0u);
  mem.mem.set_plic_source_pending(1, true);

  assert(mem.mem.read_word(npc::kPlicPriority1) == 1u);
  assert((mem.mem.read_word(npc::kPlicEnableM) & (1u << 1)) != 0u);
  assert(mem.mem.plic_irq_pending());

  npc::reset(&top, mem, nullptr, sim_time);

  bool seen_ext_interrupt = false;
  bool seen_irq_trap = false;
  uint32_t first_irq_redirect = 0;
  uint32_t first_mcause = 0;
  uint32_t first_mie = 0;
  uint32_t first_mip = 0;
  uint32_t first_mstatus = 0;
  uint32_t first_ext_line = 0;
  uint32_t first_plic_pending = 0;
  for (uint64_t cycle = 0; cycle < 2000; cycle++) {
    mem.mem.set_time_us(cycle);
    npc::tick(&top, mem, nullptr, sim_time);

    if (top.dbg_csr_irq_trap_o && !seen_irq_trap) {
      seen_irq_trap = true;
      first_irq_redirect = top.dbg_csr_irq_redirect_pc_o;
      first_mcause = top.dbg_csr_mcause_o;
      first_mie = top.dbg_csr_mie_o;
      first_mip = top.dbg_csr_mip_o;
      first_mstatus = top.dbg_csr_mstatus_o;
      first_ext_line = top.ext_irq_i;
      first_plic_pending = mem.mem.plic_pending_bits();
    }

    if (seen_irq_trap &&
        top.dbg_csr_mcause_o == kExtMcause &&
        first_irq_redirect == kTrapVector) {
      seen_ext_interrupt = true;
      break;
    }

    if (top.dbg_rob_flush_o && top.dbg_rob_flush_is_exception_o &&
        top.dbg_csr_mcause_o == kExtMcause &&
        top.dbg_rob_flush_pc_o == kTrapVector &&
        top.dbg_rob_flush_cause_o == 11) {
      seen_ext_interrupt = true;
      break;
    }
  }

  if (!seen_ext_interrupt) {
    std::cerr << "[FAIL] external interrupt not taken. "
              << "mcause=0x" << std::hex << top.dbg_csr_mcause_o
              << " mie=0x" << top.dbg_csr_mie_o
              << " mip=0x" << top.dbg_csr_mip_o
              << " flush_pc=0x" << top.dbg_rob_flush_pc_o
              << " mtvec=0x" << top.dbg_csr_mtvec_o
              << " mstatus=0x" << top.dbg_csr_mstatus_o
              << " ext_irq_i=" << std::dec << static_cast<uint32_t>(top.ext_irq_i)
              << " csr_irq_inject=" << static_cast<uint32_t>(top.dbg_csr_irq_inject_o)
              << " csr_en=" << static_cast<uint32_t>(top.dbg_csr_en_o)
              << " csr_ifetch_fault_inject="
              << static_cast<uint32_t>(top.dbg_csr_ifetch_fault_inject_o)
              << " csr_interrupt_pending="
              << static_cast<uint32_t>(top.dbg_csr_interrupt_pending_o)
              << " csr_interrupt_ext_pending="
              << static_cast<uint32_t>(top.dbg_csr_interrupt_ext_pending_o)
              << " csr_interrupt_take="
              << static_cast<uint32_t>(top.dbg_csr_interrupt_take_o)
              << " rob_empty=" << static_cast<uint32_t>(top.dbg_rob_empty_o)
              << " plic_pending=0x" << std::hex << mem.mem.plic_pending_bits()
              << " irq_trap_seen=" << std::dec << (seen_irq_trap ? 1 : 0)
              << " first_irq_redirect=0x" << std::hex << first_irq_redirect
              << " first_mcause=0x" << first_mcause
              << " first_mie=0x" << first_mie
              << " first_mip=0x" << first_mip
              << " first_mstatus=0x" << first_mstatus
              << " first_ext_line=" << std::dec << first_ext_line
              << " first_plic_pending=0x" << std::hex << first_plic_pending
              << std::dec << "\n";
    return 1;
  }

  uint32_t claim = mem.mem.read_word(npc::kPlicClaimCompleteM);
  if (claim != 1u) {
    std::cerr << "[FAIL] plic claim should return source id 1, got " << claim << "\n";
    return 1;
  }
  mem.mem.set_plic_source_pending(1, false);
  mem.mem.write_word(npc::kPlicClaimCompleteM, 1u);

  std::cout << "[PASS] test_plic" << std::endl;
  return 0;
}
