#include "trap.h"
#include <stdint.h>

static inline uintptr_t csrr_mstatus(void) {
  uintptr_t val;
  asm volatile("csrr %0, mstatus" : "=r"(val));
  return val;
}

static inline uintptr_t csrrw_mstatus(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrw %0, mstatus, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrs_mstatus_x0(void) {
  uintptr_t old;
  asm volatile("csrrs %0, mstatus, x0" : "=r"(old));
  return old;
}

static inline uintptr_t csrrc_mstatus_x0(void) {
  uintptr_t old;
  asm volatile("csrrc %0, mstatus, x0" : "=r"(old));
  return old;
}

static inline uintptr_t csrrsi_mstatus_0(void) {
  uintptr_t old;
  asm volatile("csrrsi %0, mstatus, 0" : "=r"(old));
  return old;
}

static inline uintptr_t csrrci_mstatus_0(void) {
  uintptr_t old;
  asm volatile("csrrci %0, mstatus, 0" : "=r"(old));
  return old;
}

int main() {
  uintptr_t orig = csrr_mstatus();

  csrrw_mstatus(0x123);
  check(csrr_mstatus() == 0x123);

  uintptr_t old = csrrs_mstatus_x0();
  check(old == 0x123);
  check(csrr_mstatus() == 0x123);

  old = csrrc_mstatus_x0();
  check(old == 0x123);
  check(csrr_mstatus() == 0x123);

  old = csrrsi_mstatus_0();
  check(old == 0x123);
  check(csrr_mstatus() == 0x123);

  old = csrrci_mstatus_0();
  check(old == 0x123);
  check(csrr_mstatus() == 0x123);

  csrrw_mstatus(orig);
  return 0;
}
