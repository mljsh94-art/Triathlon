#include "trap.h"
#include <stdint.h>

static inline uintptr_t csrr_mtvec(void) {
  uintptr_t val;
  asm volatile("csrr %0, mtvec" : "=r"(val));
  return val;
}

static inline uintptr_t csrrw_mtvec(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrw %0, mtvec, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrs_mtvec(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrs %0, mtvec, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrc_mtvec(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrc %0, mtvec, %1" : "=r"(old) : "r"(val));
  return old;
}

int main() {
  uintptr_t orig = csrr_mtvec();

  uintptr_t old = csrrw_mtvec(0x200);
  check(old == orig);
  check(csrr_mtvec() == 0x200);

  old = csrrs_mtvec(0x10);
  check(old == 0x200);
  check(csrr_mtvec() == 0x210);

  old = csrrc_mtvec(0x10);
  check(old == 0x210);
  check(csrr_mtvec() == 0x200);

  csrrw_mtvec(orig);
  return 0;
}
