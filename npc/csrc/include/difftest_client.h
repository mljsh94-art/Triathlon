#pragma once

#include "difftest_arch.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace npc {

struct DifftestStoreCommit {
  bool valid = false;
  uint32_t addr = 0;
  uint32_t data = 0;
  uint32_t op = 0;
};

class Difftest {
 public:
  bool init(const std::string &so_path,
            const std::vector<uint32_t> &pmem_words,
            uint32_t entry_pc);

  bool enabled() const;

  bool step_and_check(uint64_t cycle, uint32_t pc, uint32_t inst,
                      const DUTCoreState &dut_after,
                      const std::array<uint32_t, 32> &rf_before,
                      const std::array<uint32_t, 32> &rf_after,
                      const DifftestStoreCommit &store_commit,
                      bool trap_sync, bool retire_fetch_override);

  bool capture_ref_state(DUTCoreState &state_out,
                         std::vector<uint8_t> &pmem_out);
  bool restore_ref_state(const DUTCoreState &state,
                         const std::vector<uint8_t> &pmem);

  ~Difftest();

 private:
  using difftest_memcpy_t = void (*)(uint32_t, void *, size_t, bool);
  using difftest_regcpy_t = void (*)(void *, bool);
  using difftest_exec_t = void (*)(uint64_t);
  using difftest_init_t = void (*)(int);
  using difftest_raise_intr_t = void (*)(uint64_t);
  using difftest_pmem_snapshot_t = void (*)(void *, size_t, bool);

  static int32_t sext12(uint32_t imm12);
  static bool is_mmio_addr(uint32_t addr);
  static bool decode_mmio_load_rd(uint32_t inst,
                                  const std::array<uint32_t, 32> &rf_before,
                                  uint32_t &rd_out,
                                  uint32_t &addr_out);
  static bool decode_store_addr(uint32_t inst,
                                const std::array<uint32_t, 32> &rf_before,
                                uint32_t &addr_out);
  static bool is_dut_override_csr_inst(uint32_t inst);
  static bool is_atomic_mem_inst(uint32_t inst);
  static size_t lsu_store_size(uint32_t op);
  static uint32_t store_payload(uint32_t data, uint32_t op, uint32_t addr);
  void sync_store_commit_to_ref(const DifftestStoreCommit &store_commit);
  void sync_platform_mip_to_ref(DUTCoreState &ref_after,
                                const DUTCoreState &dut_after);
  bool check_arch_state(uint64_t cycle, uint32_t pc, uint32_t inst,
                        const DUTCoreState &dut_after,
                        const DUTCoreState &ref_after,
                        bool ignore_mmio_load_rd,
                        uint32_t mmio_load_rd);
  bool report_mismatch(uint64_t cycle, uint32_t pc, uint32_t inst,
                       const char *field, const DUTCoreState &dut,
                       const DUTCoreState &ref) const;
  static void dump_arch_state_compare(const DUTCoreState &dut,
                                      const DUTCoreState &ref);

  void *handle_ = nullptr;
  difftest_memcpy_t difftest_memcpy_ = nullptr;
  difftest_regcpy_t difftest_regcpy_ = nullptr;
  difftest_exec_t difftest_exec_ = nullptr;
  difftest_init_t difftest_init_ = nullptr;
  difftest_raise_intr_t difftest_raise_intr_ = nullptr;
  difftest_pmem_snapshot_t difftest_pmem_snapshot_ = nullptr;

  DUTCoreState last_ref_state_ = {};
  bool has_last_ref_state_ = false;
  bool enabled_ = false;
};

}  // namespace npc
