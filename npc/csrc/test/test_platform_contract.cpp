#include "Vtb_platform_contract.h"
#include "../include/platform_contract.h"
#include "verilated.h"

#include <cassert>
#include <cstdint>
#include <iostream>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_platform_contract top;
  top.eval();

  // Existing baseline constants.
  assert(npc::kPmemBase == 0x80000000u);
  assert(npc::kPmemSize == 0x08000000u);

  // Platform contract constants (Task 1 target).
  assert(npc::kBootRomBase == 0x00001000u);
  assert(npc::kBootRomSize == 0x00001000u);
  assert(npc::kDtbBase == 0x83F00000u);
  assert(npc::kClintBase == 0x02000000u);
  assert(npc::kPlicBase == 0x0C000000u);
  assert(npc::kUartBase == 0xA0000000u);
  assert(npc::kUartTx == 0xA00003F8u);

  // Boot handoff contract required by Linux boot requirements.
  npc::BootHandoff handoff = npc::make_default_boot_handoff();
  assert(handoff.hartid == 0u);
  assert(handoff.dtb_addr == npc::kDtbBase);
  assert(handoff.satp == 0u);

  std::cout << "[PASS] test_platform_contract" << std::endl;
  return 0;
}
