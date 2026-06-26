#pragma once

#include "args_parser.h"
#include "linux_boot_stage.h"
#include "memory_models.h"
#include "profile_collector.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <iosfwd>
#include <vector>

class Vtb_triathlon;

namespace npc {

struct CommitSlot {
  uint32_t slot = 0;
  bool we = false;
  uint32_t rd = 0;
  uint32_t data = 0;
  uint32_t pc = 0;
  uint32_t actual_npc = 0;
  uint32_t inst = 0;
  uint32_t decoded_inst = 0;
  bool is_rvc = false;
  std::array<uint32_t, 32> rf_before{};
};

// Optional trace / Linux early-debug hooks invoked from the simulation loop.
class SimObserver {
 public:
  SimObserver(const SimArgs &args, uint32_t cfg_instr_per_fetch, uint32_t cfg_commit_width);

  void configure_mem_watch(MemSystem &mem, uint32_t firmware_base, bool boot_handoff);

  void service_stq(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem);
  void after_flush(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem,
                   const std::array<uint32_t, 32> &rf);
  void after_bru_writeback(uint64_t cycle, Vtb_triathlon *top);
  void on_commit_slot(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem,
                      std::array<uint32_t, 32> &rf, const CommitSlot &slot,
                      bool store_commit_valid, uint32_t store_commit_addr,
                      uint32_t store_commit_data, uint32_t store_commit_op,
                      bool trap_sync, bool retire_fetch_override);
  void end_of_cycle(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem,
                    ProfileCollector &profile, const std::array<uint32_t, 32> &rf,
                    uint64_t no_commit_cycles);
  void dump_commit_ring(std::ostream &os) const;

 private:
  struct CommitRingEntry {
    uint64_t cycle = 0;
    uint32_t slot = 0;
    bool we = false;
    uint32_t rd = 0;
    uint32_t data = 0;
    uint32_t pc = 0;
    uint32_t actual_npc = 0;
    uint32_t inst = 0;
    uint32_t decoded_inst = 0;
    bool is_rvc = false;
    uint32_t a0 = 0;
    bool store_valid = false;
    uint32_t store_addr = 0;
    uint32_t store_data = 0;
    uint32_t store_op = 0;
    bool trap_sync = false;
    bool retire_fetch_override = false;
  };

  bool commit_trace_active(uint64_t cycle) const;
  void record_commit_ring(uint64_t cycle, const CommitSlot &slot,
                          const std::array<uint32_t, 32> &rf,
                          bool store_commit_valid, uint32_t store_commit_addr,
                          uint32_t store_commit_data, uint32_t store_commit_op,
                          bool trap_sync, bool retire_fetch_override);
  LinuxBootStageView make_linux_stage_view(uint64_t cycle, uint32_t slot, uint32_t pc,
                                           uint32_t inst, Vtb_triathlon *top,
                                           const std::array<uint32_t, 32> &rf) const;
  void emit_sv32_fault_walk(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem,
                            uint32_t cause, uint32_t src_pc, uint32_t fault_va);
  void trace_lsu(uint64_t cycle, Vtb_triathlon *top);
  void trace_commit(uint64_t cycle, const CommitSlot &slot,
                    const std::array<uint32_t, 32> &rf);
  void trace_frontend(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem);
  void emit_progress(uint64_t cycle, Vtb_triathlon *top, MemSystem &mem,
                     ProfileCollector &profile, const std::array<uint32_t, 32> &rf,
                     uint64_t no_commit_cycles);

  const SimArgs &args_;
  uint32_t cfg_instr_per_fetch_;
  uint32_t cfg_commit_width_;
  uint32_t cfg_instr_mask_;
  std::vector<CommitRingEntry> commit_ring_;
  size_t commit_ring_next_ = 0;
  size_t commit_ring_count_ = 0;

  uint32_t last_linux_wait_pc_ = 0xffffffffu;
  uint64_t last_linux_wait_log_cycle_ = 0;
  uint64_t last_uart_tx_bytes_ = 0;
  uint32_t last_flush_src_pc_ = 0xffffffffu;
  uint64_t last_flush_log_cycle_ = 0;
  uint64_t setup_vm_step_logs_ = 0;
  uint64_t create_pgd_step_logs_ = 0;
  uint64_t opensbi_step_logs_ = 0;
  uint64_t linux_reloc_step_logs_ = 0;
  uint64_t linux_fsctx_step_logs_ = 0;
  uint64_t linux_cgroup_step_logs_ = 0;
  uint64_t linux_bitops_step_logs_ = 0;
  uint64_t linux_reloc_bru_logs_ = 0;
  uint64_t linux_flush_any_logs_ = 0;
  uint64_t linux_pc_cross_logs_ = 0;
  uint64_t linux_opensbi_smode_logs_ = 0;
  uint64_t linux_satp_change_logs_ = 0;
  uint64_t linux_gp_write_logs_ = 0;
  uint64_t linux_exc_pair_step_logs_ = 0;
  uint64_t last_fw_text_write_count_ = 0;
  uint32_t last_commit_pc_seen_ = 0xffffffffu;
  uint32_t last_satp_seen_ = 0xffffffffu;
  uint64_t linux_pt_write_logs_ = 0;
  LinuxBootStageTracker linux_stages_;
};

}  // namespace npc
