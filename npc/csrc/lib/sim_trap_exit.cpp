#include "sim_trap_exit.h"

#include "memory_models.h"
#include "trap_decode.h"
#include "Vtb_triathlon.h"

#include <iostream>

namespace npc {

void print_trap_success(uint64_t cycles, ProfileCollector &profile, Vtb_triathlon *top) {
  std::cout << "HIT GOOD TRAP\n";
  const double ipc =
      cycles ? static_cast<double>(profile.total_commits()) / static_cast<double>(cycles) : 0.0;
  const double cpi = profile.total_commits()
                         ? static_cast<double>(cycles) / static_cast<double>(profile.total_commits())
                         : 0.0;
  std::cout << "IPC=" << ipc << " CPI=" << cpi << " cycles=" << cycles
            << " commits=" << profile.total_commits() << "\n";
  profile.emit_summary(cycles, top);
}

void print_trap_failure(uint32_t code, uint64_t cycles, ProfileCollector &profile,
                        Vtb_triathlon *top) {
  std::cout << "HIT BAD TRAP (code=" << code << ")\n";
  profile.emit_summary(cycles, top);
}

std::optional<int> try_ebreak_on_exception_flush(const SimArgs &args, Vtb_triathlon *top,
                                                 UnifiedMem &mem,
                                                 const std::array<uint32_t, 32> &rf,
                                                 uint64_t cycles, ProfileCollector &profile) {
  if (args.boot_handoff) {
    return std::nullopt;
  }
  if (!top->backend_flush_o || !top->dbg_rob_flush_o || !top->dbg_rob_flush_is_exception_o) {
    return std::nullopt;
  }
  const uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
  const uint32_t src_inst = mem.read_word(src_pc);
  if (!is_ebreak_insn_word(src_inst, src_pc)) {
    return std::nullopt;
  }
  const uint32_t code = rf[10];
  if (code == 0) {
    print_trap_success(cycles, profile, top);
    return 0;
  }
  print_trap_failure(code, cycles, profile, top);
  return 1;
}

std::optional<int> try_ebreak_on_commit(const SimArgs &args, uint32_t inst, uint32_t pc,
                                        uint32_t decoded_inst, bool is_rvc,
                                        const std::array<uint32_t, 32> &rf, uint64_t cycles,
                                        ProfileCollector &profile, Vtb_triathlon *top) {
  if (args.boot_handoff) {
    return std::nullopt;
  }
  if (!is_ebreak_insn_word(inst, pc) && !(is_rvc && decoded_inst == kEbreakInsn)) {
    return std::nullopt;
  }
  const uint32_t code = rf[10];
  if (code == 0) {
    print_trap_success(cycles, profile, top);
    return 0;
  }
  print_trap_failure(code, cycles, profile, top);
  return 1;
}

}  // namespace npc
