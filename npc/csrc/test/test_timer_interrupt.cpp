#include "Vtb_timer_interrupt.h"
#include "../include/memory_models.h"
#include "verilated.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kTrapVector = 0x80000100u;
constexpr uint32_t kTimerMcause = 0x80000007u;

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

  Vtb_timer_interrupt top;
  npc::MemSystem mem;
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;
  vluint64_t sim_time = 0;

  const uint32_t base = npc::kPmemBase;

  // Build a tiny setup sequence:
  // 1) mtvec <- 0x80000100
  // 2) mie.MTIE <- 1
  // 3) mstatus.MIE <- 1
  // 4) WFI + spin
  mem.mem.write_word(base + 0x00, insn_lui(1, 0x80000));    // x1 = 0x80000000
  mem.mem.write_word(base + 0x04, insn_addi(1, 1, 0x100));  // x1 = 0x80000100
  mem.mem.write_word(base + 0x08, insn_csrrw(0, 1, 0x305)); // csrw mtvec, x1
  mem.mem.write_word(base + 0x0c, insn_addi(2, 0, 0x80));   // x2 = MTIE bit
  mem.mem.write_word(base + 0x10, insn_csrrw(0, 2, 0x304)); // csrw mie, x2
  mem.mem.write_word(base + 0x14, insn_addi(3, 0, 0x08));   // x3 = MIE bit
  mem.mem.write_word(base + 0x18, insn_csrrs(0, 3, 0x300)); // csrs mstatus, x3
  mem.mem.write_word(base + 0x1c, 0x10500073u);             // wfi
  mem.mem.write_word(base + 0x20, insn_beq(0, 0, -4));      // spin

  mem.mem.write_word(kTrapVector + 0x00, 0x00000013u);

  // CLINT MMIO smoke check.
  mem.mem.write_word(npc::kClintMtimecmpLow, 80u);
  mem.mem.write_word(npc::kClintMtimecmpHigh, 0u);
  assert(mem.mem.read_word(npc::kClintMtimecmpLow) == 80u);
  assert(mem.mem.read_word(npc::kClintMtimecmpHigh) == 0u);

  npc::reset(&top, mem, nullptr, sim_time);

  bool seen_timer_interrupt = false;
  bool seen_irq_trap = false;
  uint32_t first_irq_mtvec = 0;
  uint32_t first_irq_redirect = 0;
  uint32_t first_rob_async_valid = 0;
  uint32_t first_rob_async_redirect = 0;
  uint32_t first_rob_flush = 0;
  uint32_t first_rob_flush_pc = 0;
  for (uint64_t cycle = 0; cycle < 2000; cycle++) {
    mem.mem.set_time_us(cycle);
    mem.drive(&top);
    top.clk_i = 0;
    top.eval();
    sim_time++;
    if (top.dbg_csr_irq_trap_o) {
      if (!seen_irq_trap) {
        first_irq_mtvec = top.dbg_csr_mtvec_o;
        first_irq_redirect = top.dbg_csr_irq_redirect_pc_o;
        first_rob_async_valid = top.dbg_rob_async_valid_o;
        first_rob_async_redirect = top.dbg_rob_async_redirect_pc_o;
        first_rob_flush = top.dbg_rob_flush_o;
        first_rob_flush_pc = top.dbg_rob_flush_pc_o;
      }
      seen_irq_trap = true;
    }

    if (seen_irq_trap &&
        top.dbg_csr_mcause_o == kTimerMcause &&
        first_irq_redirect == kTrapVector &&
        first_rob_async_valid == 1u &&
        first_rob_async_redirect == kTrapVector) {
      seen_timer_interrupt = true;
      break;
    }

    if (top.dbg_rob_flush_o && top.dbg_rob_flush_is_exception_o) {
      if (top.dbg_csr_mcause_o == kTimerMcause &&
          top.dbg_rob_flush_pc_o == kTrapVector &&
          top.dbg_rob_flush_cause_o == 7) {
        seen_timer_interrupt = true;
        break;
      }
    }

    top.clk_i = 1;
    top.eval();
    sim_time++;

    if (top.dbg_rob_flush_o && top.dbg_rob_flush_is_exception_o) {
      if (top.dbg_csr_mcause_o == kTimerMcause &&
          top.dbg_rob_flush_pc_o == kTrapVector &&
          top.dbg_rob_flush_cause_o == 7) {
        seen_timer_interrupt = true;
        break;
      }
    }

    mem.observe(&top);
  }

  if (!seen_timer_interrupt) {
    std::cerr << "[FAIL] timer interrupt not taken as expected. "
              << "mcause=0x" << std::hex << top.dbg_csr_mcause_o
              << " flush_pc=0x" << top.dbg_rob_flush_pc_o
              << " mtvec=0x" << top.dbg_csr_mtvec_o
              << " mstatus=0x" << top.dbg_csr_mstatus_o
              << " first_irq_mtvec=0x" << std::hex << first_irq_mtvec
              << " first_irq_redirect=0x" << std::hex << first_irq_redirect
              << " first_rob_async_valid=" << std::dec << first_rob_async_valid
              << " first_rob_async_redirect=0x" << std::hex << first_rob_async_redirect
              << " first_rob_flush=" << std::dec << first_rob_flush
              << " first_rob_flush_pc=0x" << std::hex << first_rob_flush_pc
              << " irq_trap_seen=" << (seen_irq_trap ? 1 : 0)
              << std::dec << "\n";
    return 1;
  }

  std::cout << "[PASS] test_timer_interrupt" << std::endl;
  return 0;
}
