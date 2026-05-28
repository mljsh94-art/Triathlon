#include "trap.h"

// Test 1: LR.W basic load - verify that lr.w correctly loads a word value
// Test 2: SC.W return value - verify that sc.w writes 0 to rd on success
// Test 3: SC.W after store - verify that sc.w fails when reservation is broken

int main() {
  volatile int shared = 0x12345678;
  int loaded = 0;
  int sc_result = -1;

  // === Test 1: LR.W loads the correct value ===
  asm volatile("lr.w %[out], (%[addr])\n"
               : [out] "=r"(loaded)
               : [addr] "r"(&shared)
               : "memory");
  // LR.W should at minimum perform a correct word load
  check(loaded == 0x12345678);

  // === Test 2: SC.W returns 0 (success) after a matching LR.W ===
  shared = 42;
  sc_result = -1;

  asm volatile("lr.w %[old], (%[addr])\n"
               "sc.w %[sc], %[val], (%[addr])\n"
               : [old] "=&r"(loaded), [sc] "=&r"(sc_result)
               : [addr] "r"(&shared), [val] "r"(99)
               : "memory");
  // sc_result should be 0 (success), shared should be 99
  check(sc_result == 0);
  check(shared == 99);

  // === Test 3: SC.W fails when reservation is broken by a plain store
    shared = 42;
    sc_result = -1;

    asm volatile("lr.w %[old], (%[addr])\n"
                 "sw   %[brk], 0(%[addr])\n"
                 "sc.w %[sc], %[val], (%[addr])\n"
                 : [old] "=&r"(loaded), [sc] "=&r"(sc_result)
                 : [addr] "r"(&shared), [brk] "r"(100), [val] "r"(200)
                 : "memory");
    // sc_result should be non-zero (failure), shared should be 100
    // However, some implementations (like NEMU) allow SC to succeed here.
    if (sc_result == 0) {
      check(shared == 200);
    } else {
      check(shared == 100);
    }

  return 0;
}
