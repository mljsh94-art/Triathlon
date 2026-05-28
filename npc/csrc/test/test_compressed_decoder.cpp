#include "Vtb_compressed_decoder.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

struct Case32 {
  const char *name;
  uint32_t instr_i;
  uint32_t instr_o;
  bool is_compressed;
  bool is_illegal;
};

void expect_eq_u32(const char *name, const char *field, uint32_t got,
                   uint32_t exp) {
  if (got != exp) {
    std::cerr << "[fail] " << name << " " << field << " got=0x" << std::hex
              << got << " exp=0x" << exp << std::dec << std::endl;
    std::exit(1);
  }
}

void expect_eq_bool(const char *name, const char *field, bool got, bool exp) {
  if (got != exp) {
    std::cerr << "[fail] " << name << " " << field << " got=" << got
              << " exp=" << exp << std::endl;
    std::exit(1);
  }
}

} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_compressed_decoder top;

  const std::vector<Case32> kCases = {
      // passthrough for non-compressed instruction.
      {"rv32-add", 0x00c585b3u, 0x00c585b3u, false, false},

      // RV32C integer subset (directed pairs generated from GNU binutils).
      {"c.addi4spn", 0x00000800u, 0x01010413u, true, false},
      {"c.lw", 0x00004144u, 0x00452483u, true, false},
      {"c.sw", 0x0000c60cu, 0x00b62423u, true, false},
      {"c.addi", 0x00000685u, 0x00168693u, true, false},
      {"c.jal", 0x00002001u, 0x000000efu, true, false},
      {"c.li", 0x00005775u, 0xffd00713u, true, false},
      {"c.addi16sp", 0x00006141u, 0x01010113u, true, false},
      {"c.lui", 0x00006785u, 0x000017b7u, true, false},
      {"c.srli", 0x0000800du, 0x00345413u, true, false},
      {"c.srli-sh12-x12", 0x00008231u, 0x00c65613u, true, false},
      {"c.srai", 0x00008489u, 0x4024d493u, true, false},
      {"c.andi", 0x00009971u, 0xffc57513u, true, false},
      {"c.sub", 0x00008d91u, 0x40c585b3u, true, false},
      {"c.xor", 0x00008db1u, 0x00c5c5b3u, true, false},
      {"c.or", 0x00008dd1u, 0x00c5e5b3u, true, false},
      {"c.and", 0x00008df1u, 0x00c5f5b3u, true, false},
      {"c.j", 0x0000a021u, 0x0080006fu, true, false},
      {"c.beqz", 0x0000c019u, 0x00040363u, true, false},
      {"c.bnez", 0x0000e091u, 0x00049263u, true, false},
      {"c.slli", 0x0000050au, 0x00251513u, true, false},
      {"c.slli-sh10-x12", 0x0000062au, 0x00a61613u, true, false},
      {"c.lwsp", 0x000045b2u, 0x00c12583u, true, false},
      {"c.jr", 0x00008082u, 0x00008067u, true, false},
      {"c.mv", 0x00008636u, 0x00d00633u, true, false},
      {"c.ebreak", 0x00009002u, 0x00100073u, true, false},
      {"c.jalr", 0x00009102u, 0x000100e7u, true, false},
      {"c.add", 0x0000973eu, 0x00f70733u, true, false},
      {"c.swsp", 0x0000c82au, 0x00a12823u, true, false},

      // Illegal encodings in RV32C.
      {"c.addi4spn-zero-imm", 0x00000000u, 0x00000000u, true, true},
      {"c.lwsp-rd0", 0x00004002u, 0x00000000u, true, true},
      {"c.jr-rs1-zero", 0x00008002u, 0x00000000u, true, true},
      {"c.lui-rd0", 0x00006001u, 0x00000000u, true, true},
  };

  for (const auto &tc : kCases) {
    top.instr_i = tc.instr_i;
    top.eval();

    expect_eq_u32(tc.name, "instr_o", top.instr_o, tc.instr_o);
    expect_eq_bool(tc.name, "is_compressed_o", top.is_compressed_o,
                   tc.is_compressed);
    expect_eq_bool(tc.name, "is_illegal_o", top.is_illegal_o, tc.is_illegal);
  }

  std::cout << "[PASS] compressed_decoder directed cases" << std::endl;
  return 0;
}
