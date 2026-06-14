#pragma once

#include <cstddef>
#include <cstdint>

namespace npc {

// Shared architectural snapshot for DUT <-> Spike difftest regcpy.
// Field order must match npc/ref/spike-diff/difftest.cc diff_get/set_regs().
struct DUTCoreState {
  uint32_t gpr[32];
  uint32_t pc;
  uint32_t priv;  // 0=U, 1=S, 3=M (Spike PRV_*)
  uint32_t mstatus;
  uint32_t sstatus;
  uint32_t mepc;
  uint32_t sepc;
  uint32_t mcause;
  uint32_t scause;
  uint32_t mtval;
  uint32_t stval;
  uint32_t mtvec;
  uint32_t stvec;
  uint32_t mscratch;
  uint32_t sscratch;
  uint32_t mie;
  uint32_t mip;
  uint32_t medeleg;
  uint32_t mideleg;
  uint32_t satp;
};

inline constexpr bool kDiffTestToDut = false;
inline constexpr bool kDiffTestToRef = true;

static_assert(sizeof(DUTCoreState) == (32 + 1 + 18) * sizeof(uint32_t),
              "DUTCoreState layout drift");

}  // namespace npc
