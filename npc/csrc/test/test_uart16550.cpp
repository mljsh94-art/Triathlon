#include "Vtb_uart16550.h"
#include "../include/memory_models.h"
#include "verilated.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

uint8_t read8(const npc::UnifiedMem &mem, uint32_t addr) {
  const uint32_t word = mem.read_word(addr & ~0x3u);
  return static_cast<uint8_t>((word >> ((addr & 0x3u) * 8u)) & 0xffu);
}

void write8(npc::UnifiedMem &mem, uint32_t addr, uint8_t data) {
  mem.write_store(addr, data, 7u);  // sb
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_uart16550 top;
  top.eval();

  npc::UnifiedMem mem;
  const uint32_t uart = npc::kUartTx;

  // LSR should indicate TX ready at reset.
  assert((read8(mem, uart + 5u) & 0x60u) == 0x60u);
  // IIR should indicate no pending interrupt.
  assert((read8(mem, uart + 2u) & 0x01u) == 0x01u);

  // DLAB path: write/read divisor latch.
  write8(mem, uart + 3u, 0x80u);  // LCR.DLAB=1
  write8(mem, uart + 0u, 0x34u);  // DLL
  write8(mem, uart + 1u, 0x12u);  // DLM
  assert(read8(mem, uart + 0u) == 0x34u);
  assert(read8(mem, uart + 1u) == 0x12u);

  // Normal path: IER and SCR read/write.
  write8(mem, uart + 3u, 0x03u);  // 8N1, DLAB=0
  write8(mem, uart + 1u, 0x0fu);  // IER
  write8(mem, uart + 7u, 0x5au);  // SCR
  assert(read8(mem, uart + 1u) == 0x0fu);
  assert(read8(mem, uart + 7u) == 0x5au);

  std::cout << "[PASS] test_uart16550" << std::endl;
  return 0;
}
