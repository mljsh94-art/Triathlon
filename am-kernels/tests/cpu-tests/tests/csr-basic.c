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

static inline uintptr_t csrrs_mstatus(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrs %0, mstatus, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrc_mstatus(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrc %0, mstatus, %1" : "=r"(old) : "r"(val));
  return old;
}

static inline uintptr_t csrrsi_mstatus_3(void) {
  uintptr_t old;
  asm volatile("csrrsi %0, mstatus, 3" : "=r"(old));
  return old;
}

static inline uintptr_t csrrci_mstatus_1(void) {
  uintptr_t old;
  asm volatile("csrrci %0, mstatus, 1" : "=r"(old));
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

static inline uintptr_t csrrwi_mstatus_1f(void) {
  uintptr_t old;
  asm volatile("csrrwi %0, mstatus, 31" : "=r"(old));
  return old;
}

static inline uintptr_t csrr_mepc(void) {
  uintptr_t val;
  asm volatile("csrr %0, mepc" : "=r"(val));
  return val;
}

static inline uintptr_t csrrw_mepc(uintptr_t val) {
  uintptr_t old;
  asm volatile("csrrw %0, mepc, %1" : "=r"(old) : "r"(val));
  return old;
}

int main() {
  uintptr_t orig_mstatus = csrr_mstatus();
  uintptr_t orig_mepc = csrr_mepc();

  uintptr_t old = csrrw_mstatus(0x5);
  check(old == orig_mstatus);
  check(csrr_mstatus() == 0x0);

  old = csrrs_mstatus(0x10);
  check(old == 0x0);
  check(csrr_mstatus() == 0x0);

  old = csrrc_mstatus(0x1);
  check(old == 0x0);
  check(csrr_mstatus() == 0x0);

  old = csrrsi_mstatus_3();
  check(old == 0x0);
  check(csrr_mstatus() == 0x2);

  old = csrrci_mstatus_1();
  check(old == 0x2);
  check(csrr_mstatus() == 0x2);

  old = csrrsi_mstatus_0();
  check(old == 0x2);
  check(csrr_mstatus() == 0x2);

  old = csrrci_mstatus_0();
  check(old == 0x2);
  check(csrr_mstatus() == 0x2);

  old = csrrwi_mstatus_1f();
  check(old == 0x2);
  check(csrr_mstatus() == 0xa);

  old = csrrw_mepc(0x1234);
  check(old == orig_mepc);
  check(csrr_mepc() == 0x1234);

  csrrw_mstatus(orig_mstatus);
  csrrw_mepc(orig_mepc);

  return 0;
}
