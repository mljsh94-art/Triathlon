#pragma once

#include "platform_contract.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace npc {

inline constexpr uint32_t kBootStubBase = kBootRomBase;
inline constexpr uint32_t kOpenSbiLoadBase = kPmemBase + 0x00020000u;
inline constexpr uint32_t kCsrSatp = 0x180u;

inline constexpr uint32_t kFdtMagic = 0xd00dfeedu;
inline constexpr uint32_t kFdtVersion = 17u;
inline constexpr uint32_t kFdtLastCompVersion = 16u;
inline constexpr uint32_t kFdtMinBlobSize = 0x28u;

inline uint32_t enc_i(uint32_t imm12, uint32_t rs1, uint32_t funct3, uint32_t rd,
                      uint32_t opcode) {
  return ((imm12 & 0xfffu) << 20) | ((rs1 & 0x1fu) << 15) | ((funct3 & 0x7u) << 12) |
         ((rd & 0x1fu) << 7) | (opcode & 0x7fu);
}

inline uint32_t enc_u(uint32_t imm31_12, uint32_t rd, uint32_t opcode) {
  return ((imm31_12 & 0xfffffu) << 12) | ((rd & 0x1fu) << 7) | (opcode & 0x7fu);
}

inline uint32_t insn_lui(uint32_t rd, uint32_t imm31_12) { return enc_u(imm31_12, rd, 0x37u); }
inline uint32_t insn_addi(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(static_cast<uint32_t>(imm), rs1, 0x0u, rd, 0x13u);
}
inline uint32_t insn_csrrw(uint32_t rd, uint32_t rs1, uint32_t csr) {
  return enc_i(csr, rs1, 0x1u, rd, 0x73u);
}
inline uint32_t insn_jalr(uint32_t rd, uint32_t rs1, int32_t imm) {
  return enc_i(static_cast<uint32_t>(imm), rs1, 0x0u, rd, 0x67u);
}

inline void emit_load_imm32(std::vector<uint32_t> &out, uint32_t rd, uint32_t value) {
  uint32_t hi20 = (value + 0x800u) >> 12;
  int32_t low12 = static_cast<int32_t>(value & 0xfffu);
  if ((low12 & 0x800) != 0) low12 -= 0x1000;

  out.push_back(insn_lui(rd, hi20));
  out.push_back(insn_addi(rd, rd, low12));
}

inline std::vector<uint32_t> make_boot_handoff_stub(uint32_t firmware_entry,
                                                     const BootHandoff &handoff) {
  std::vector<uint32_t> words;
  words.reserve(12);

  emit_load_imm32(words, 10, handoff.hartid);    // a0 = hartid
  emit_load_imm32(words, 11, handoff.dtb_addr);  // a1 = dtb

  if (handoff.satp == 0u) {
    // csrw satp, x0
    words.push_back(insn_csrrw(0, 0, kCsrSatp));
  } else {
    emit_load_imm32(words, 12, handoff.satp);
    words.push_back(insn_csrrw(0, 12, kCsrSatp));
  }

  emit_load_imm32(words, 1, firmware_entry);  // x1 = firmware entry
  words.push_back(insn_jalr(0, 1, 0));        // jump x1
  words.push_back(0x00000013u);               // nop (safety padding)
  return words;
}

inline std::vector<uint32_t> make_jump_stub(uint32_t target_pc) {
  std::vector<uint32_t> words;
  words.reserve(4);
  emit_load_imm32(words, 1, target_pc);  // x1 = target
  words.push_back(insn_jalr(0, 1, 0));   // jump x1
  words.push_back(0x00000013u);          // nop (safety padding)
  return words;
}

template <typename MemT>
inline void install_boot_handoff_stub(MemT &mem, uint32_t firmware_entry,
                                      const BootHandoff &handoff,
                                      uint32_t stub_base = kBootStubBase) {
  const auto words = make_boot_handoff_stub(firmware_entry, handoff);
  for (size_t i = 0; i < words.size(); i++) {
    mem.write_word(stub_base + static_cast<uint32_t>(i) * 4u, words[i]);
  }
}

template <typename MemT>
inline void install_jump_stub(MemT &mem, uint32_t target_pc, uint32_t stub_base) {
  const auto words = make_jump_stub(target_pc);
  for (size_t i = 0; i < words.size(); i++) {
    mem.write_word(stub_base + static_cast<uint32_t>(i) * 4u, words[i]);
  }
}

template <typename MemT>
inline void install_minimal_dtb(MemT &mem, uint32_t dtb_addr = kDtbBase) {
  // Minimal FDT header placeholder. Full DTB will be loaded from file in real flow.
  mem.write_word(dtb_addr + 0x00u, kFdtMagic);
  mem.write_word(dtb_addr + 0x04u, kFdtMinBlobSize);
  mem.write_word(dtb_addr + 0x08u, 0x10u);  // off_dt_struct
  mem.write_word(dtb_addr + 0x0cu, 0x20u);  // off_dt_strings
  mem.write_word(dtb_addr + 0x10u, 0x28u);  // off_mem_rsvmap
  mem.write_word(dtb_addr + 0x14u, kFdtVersion);
  mem.write_word(dtb_addr + 0x18u, kFdtLastCompVersion);
  mem.write_word(dtb_addr + 0x1cu, 0u);  // boot_cpuid_phys
  mem.write_word(dtb_addr + 0x20u, 0u);  // size_dt_strings
  mem.write_word(dtb_addr + 0x24u, 0u);  // size_dt_struct
}

}  // namespace npc
