#pragma once

#include <cstdint>

namespace npc {

constexpr uint32_t kEbreakInsn = 0x00100073u;
constexpr uint16_t kCEbreakInsn = 0x9002u;

inline bool is_ebreak_insn_word(uint32_t insn_word, uint32_t pc) {
  if ((pc & 0x1u) != 0u) return false;

  uint32_t half_shift = (pc & 0x2u) ? 16u : 0u;
  uint16_t insn16 = static_cast<uint16_t>((insn_word >> half_shift) & 0xffffu);

  if (insn16 == kCEbreakInsn) return true;
  if (half_shift == 0u && insn_word == kEbreakInsn) return true;
  return false;
}

}  // namespace npc

