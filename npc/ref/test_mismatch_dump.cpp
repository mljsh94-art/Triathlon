// Temporary demo: inject a deliberate GPR mismatch and exercise dump_arch_state_compare().
#include "difftest_client.h"
#include "platform_contract.h"

#include <array>
#include <cstdlib>
#include <iostream>
#include <vector>

int main(int argc, char **argv) {
  const char *so_path =
      (argc > 1) ? argv[1] : "riscv32-spike-difftest.so";

  // addi x1, x0, 42
  constexpr uint32_t kInst = 0x02a00093u;

  npc::Difftest difftest;
  std::vector<uint32_t> image = {kInst};
  if (!difftest.init(so_path, image, npc::kPmemBase)) {
    return 1;
  }

  std::array<uint32_t, 32> rf_before{};
  std::array<uint32_t, 32> rf_after{};
  rf_after[1] = 99u;

  npc::DUTCoreState dut_after = {};
  dut_after.pc = npc::kPmemBase + 4u;
  dut_after.priv = 3;
  dut_after.mstatus = 0x1800u;
  dut_after.gpr[1] = 99u;  // Spike ref will have 42 after addi

  bool ok = difftest.step_and_check(1, npc::kPmemBase, kInst, dut_after, rf_before,
                                    rf_after);
  if (ok) {
    std::cerr << "[demo] expected mismatch but step_and_check passed\n";
    return 1;
  }

  std::cout << "[demo] mismatch dump demo OK\n";
  return 0;
}
