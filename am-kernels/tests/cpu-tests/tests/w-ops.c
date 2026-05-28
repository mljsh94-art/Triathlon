#include "trap.h"
#include <stdint.h>

#if __riscv_xlen == 64

static inline int64_t sext32(uint32_t v) {
  return (int64_t)(int32_t)v;
}

#define ADDIW(a, imm)                                                       \
  ({                                                                        \
    int64_t _r;                                                             \
    asm volatile("addiw %0, %1, %2" : "=r"(_r) : "r"(a), "i"(imm)); \
    _r;                                                                     \
  })
#define SLLIW(a, sh)                                                       \
  ({                                                                        \
    int64_t _r;                                                             \
    asm volatile("slliw %0, %1, %2" : "=r"(_r) : "r"(a), "i"(sh));  \
    _r;                                                                     \
  })
#define SRLIW(a, sh)                                                       \
  ({                                                                        \
    int64_t _r;                                                             \
    asm volatile("srliw %0, %1, %2" : "=r"(_r) : "r"(a), "i"(sh));  \
    _r;                                                                     \
  })
#define SRAIW(a, sh)                                                       \
  ({                                                                        \
    int64_t _r;                                                             \
    asm volatile("sraiw %0, %1, %2" : "=r"(_r) : "r"(a), "i"(sh));  \
    _r;                                                                     \
  })

static inline int64_t addw(int64_t a, int64_t b) {
  int64_t r;
  asm volatile("addw %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int64_t subw(int64_t a, int64_t b) {
  int64_t r;
  asm volatile("subw %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int64_t sllw(int64_t a, int64_t b) {
  int64_t r;
  asm volatile("sllw %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int64_t srlw(int64_t a, int64_t b) {
  int64_t r;
  asm volatile("srlw %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int64_t sraw(int64_t a, int64_t b) {
  int64_t r;
  asm volatile("sraw %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

int main() {
  int64_t vals[] = {
    0,
    1,
    -1,
    0x7fffffffLL,
    0x80000000LL,
    0x00000001ffffffffLL,
    0xffffffff00000000LL,
    0x12345678deadbeefLL,
  };
  int shifts[] = {0, 1, 7, 15, 31};

  int vcount = (int)(sizeof(vals) / sizeof(vals[0]));
  int scount = (int)(sizeof(shifts) / sizeof(shifts[0]));

  for (int i = 0; i < vcount; i++) {
    int64_t a = vals[i];
    check(ADDIW(a, 1) == sext32((uint32_t)a + 1u));
    check(ADDIW(a, -1) == sext32((uint32_t)a - 1u));
    check(SLLIW(a, 1) == sext32((uint32_t)a << 1));
    check(SRLIW(a, 1) == sext32((uint32_t)a >> 1));
    check(SRAIW(a, 1) == sext32((int32_t)a >> 1));
    check(SLLIW(a, 31) == sext32((uint32_t)a << 31));
    check(SRLIW(a, 31) == sext32((uint32_t)a >> 31));
    check(SRAIW(a, 31) == sext32((int32_t)a >> 31));

    for (int j = 0; j < vcount; j++) {
      int64_t b = vals[j];
      check(addw(a, b) == sext32((uint32_t)a + (uint32_t)b));
      check(subw(a, b) == sext32((uint32_t)a - (uint32_t)b));
    }

    for (int j = 0; j < scount; j++) {
      int sh = shifts[j] & 0x1f;
      check(sllw(a, sh) == sext32((uint32_t)a << sh));
      check(srlw(a, sh) == sext32((uint32_t)a >> sh));
      check(sraw(a, sh) == sext32((int32_t)a >> sh));
    }
  }

  return 0;
}

#else
int main() { return 0; }
#endif
