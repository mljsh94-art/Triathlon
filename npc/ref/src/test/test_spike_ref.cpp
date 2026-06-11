#include "difftest_arch.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

namespace {

constexpr uint32_t kPmemBase = 0x80000000u;
// addi x1, x0, 42
constexpr uint32_t kTestInst = 0x02a00093u;

using difftest_init_t = void (*)(int);
using difftest_memcpy_t = void (*)(uint32_t, void *, size_t, bool);
using difftest_regcpy_t = void (*)(void *, bool);
using difftest_exec_t = void (*)(uint64_t);

template <typename T>
T load_sym(void *handle, const char *name) {
  dlerror();
  auto fn = reinterpret_cast<T>(dlsym(handle, name));
  const char *err = dlerror();
  if (err != nullptr || fn == nullptr) {
    std::fprintf(stderr, "[smoke] dlsym(%s) failed: %s\n", name,
                 err != nullptr ? err : "null symbol");
    std::exit(1);
  }
  return fn;
}

}  // namespace

int main(int argc, char **argv) {
  const char *so_path =
      (argc > 1) ? argv[1] : "riscv32-spike-difftest.so";

  void *handle = dlopen(so_path, RTLD_LAZY | RTLD_LOCAL);
  if (handle == nullptr) {
    std::fprintf(stderr, "[smoke] dlopen(%s) failed: %s\n", so_path, dlerror());
    return 1;
  }

  auto difftest_init = load_sym<difftest_init_t>(handle, "difftest_init");
  auto difftest_memcpy = load_sym<difftest_memcpy_t>(handle, "difftest_memcpy");
  auto difftest_regcpy = load_sym<difftest_regcpy_t>(handle, "difftest_regcpy");
  auto difftest_exec = load_sym<difftest_exec_t>(handle, "difftest_exec");

  difftest_init(0);

  uint32_t image = kTestInst;
  difftest_memcpy(kPmemBase, &image, sizeof(image), npc::kDiffTestToRef);

  npc::DUTCoreState boot = {};
  boot.pc = kPmemBase;
  boot.priv = 3;
  boot.mstatus = 0x1800u;
  difftest_regcpy(&boot, npc::kDiffTestToRef);

  difftest_exec(1);

  npc::DUTCoreState after = {};
  difftest_regcpy(&after, npc::kDiffTestToDut);

  if (after.gpr[1] != 42u) {
    std::fprintf(stderr,
                 "[smoke] FAIL: x1=0x%x (expected 42), pc=0x%x\n",
                 after.gpr[1], after.pc);
    return 1;
  }
  if (after.pc != kPmemBase + 4u) {
    std::fprintf(stderr,
                 "[smoke] FAIL: pc=0x%x (expected 0x%08x)\n",
                 after.pc, kPmemBase + 4u);
    return 1;
  }

  std::printf("[smoke] PASS: x1=42 pc=0x%08x priv=%u mstatus=0x%x\n",
              after.pc, after.priv, after.mstatus);
  return 0;
}
