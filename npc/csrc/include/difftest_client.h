#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace npc {

struct DUTCSRState {
  uint32_t mtvec;
  uint32_t mepc;
  uint32_t mstatus;
  uint32_t mcause;
};

class Difftest {
 public:
  bool init(const std::string &so_path,
            const std::vector<uint32_t> &pmem_words,
            uint32_t entry_pc);

  bool enabled() const;

  bool step_and_check(uint64_t cycle, uint32_t pc, uint32_t inst,
                      const std::array<uint32_t, 32> &rf_before,
                      const std::array<uint32_t, 32> &rf_after);

  bool check_arch_state(uint64_t cycle,
                        const std::array<uint32_t, 32> &rf_after,
                        const DUTCSRState &dut_csr);

  ~Difftest();

 private:
  struct DifftestCPUState {
    uint32_t gpr[32];
    uint32_t pc;
    struct {
      uint32_t mtvec;
      uint32_t mepc;
      uint32_t mstatus;
      uint32_t mcause;
    } csr;
  };

  using difftest_memcpy_t = void (*)(uint32_t, void *, size_t, bool);
  using difftest_regcpy_t = void (*)(void *, bool);
  using difftest_exec_t = void (*)(uint64_t);
  using difftest_init_t = void (*)(int);

  static constexpr bool kToDut = false;
  static constexpr bool kToRef = true;

  static int32_t sext12(uint32_t imm12);
  static bool is_mmio_addr(uint32_t addr);
  static bool decode_mmio_load_rd(uint32_t inst,
                                  const std::array<uint32_t, 32> &rf_before,
                                  uint32_t &rd_out);

  void *handle_ = nullptr;
  difftest_memcpy_t difftest_memcpy_ = nullptr;
  difftest_regcpy_t difftest_regcpy_ = nullptr;
  difftest_exec_t difftest_exec_ = nullptr;
  difftest_init_t difftest_init_ = nullptr;

  DifftestCPUState last_ref_state_ = {};
  bool has_last_ref_state_ = false;
  bool enabled_ = false;
};

}  // namespace npc
