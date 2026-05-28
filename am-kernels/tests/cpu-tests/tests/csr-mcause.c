#include "trap.h"
#include <stdint.h>

static inline uintptr_t csrr_mcause(void) {
  uintptr_t val;
  asm volatile("csrr %0, mcause" : "=r"(val));
  return val;
}

static inline uintptr_t csrrw_mcause(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrw %0, mcause, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrs_mcause(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrs %0, mcause, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrc_mcause(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrc %0, mcause, %1" : "=r"(old) : "r"(val));
  return old;
}

int main() {
  uintptr_t orig = csrr_mcause();

  uintptr_t old = csrrw_mcause(0x55);
  check(old == orig);
  check(csrr_mcause() == 0x55);

  old = csrrs_mcause(0x0f);
  check(old == 0x55);
  check(csrr_mcause() == (0x55 | 0x0f));

  old = csrrc_mcause(0x05);
  check(old == (0x55 | 0x0f));
  check(csrr_mcause() == ((0x55 | 0x0f) & ~0x05));

  csrrw_mcause(orig);
  return 0;
}
