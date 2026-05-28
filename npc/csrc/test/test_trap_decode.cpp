#include "../include/trap_decode.h"

#include "Vtb_trap_decode.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>

static void expect_true(bool cond, const char *msg) {
  if (!cond) {
    std::printf("[ \x1b[31mFAIL\x1b[0m ] %s\n", msg);
    std::exit(1);
  }
  std::printf("[ \x1b[32mPASS\x1b[0m ] %s\n", msg);
}

static void expect_false(bool cond, const char *msg) { expect_true(!cond, msg); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_trap_decode top;
  top.eval();

  // 32-bit ebreak
  expect_true(npc::is_ebreak_insn_word(0x00100073u, 0u), "ebreak-32-low-half");
  // compressed ebreak at low halfword: [15:0]=0x9002
  expect_true(npc::is_ebreak_insn_word(0xa0019002u, 0u), "cebreak-low-half");
  // compressed ebreak at high halfword: [31:16]=0x9002
  expect_true(npc::is_ebreak_insn_word(0x90028082u, 2u), "cebreak-high-half");

  expect_false(npc::is_ebreak_insn_word(0xa0018082u, 0u), "non-ebreak");
  return 0;
}
