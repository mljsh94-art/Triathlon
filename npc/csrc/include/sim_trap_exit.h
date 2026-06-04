#pragma once

#include "args_parser.h"
#include "profile_collector.h"

#include <array>
#include <cstdint>
#include <optional>

class Vtb_triathlon;
class VerilatedVcdC;

namespace npc {

class UnifiedMem;

void print_trap_success(uint64_t cycles, ProfileCollector &profile, Vtb_triathlon *top);
void print_trap_failure(uint32_t code, uint64_t cycles, ProfileCollector &profile,
                        Vtb_triathlon *top);

// Returns exit code when simulation should stop; nullopt to continue.
std::optional<int> try_ebreak_on_exception_flush(const SimArgs &args, Vtb_triathlon *top,
                                               UnifiedMem &mem,
                                               const std::array<uint32_t, 32> &rf,
                                               uint64_t cycles, ProfileCollector &profile);

std::optional<int> try_ebreak_on_commit(const SimArgs &args, uint32_t inst, uint32_t pc,
                                        uint32_t decoded_inst, bool is_rvc,
                                        const std::array<uint32_t, 32> &rf, uint64_t cycles,
                                        ProfileCollector &profile, Vtb_triathlon *top);

}  // namespace npc
