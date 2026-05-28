/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <isa.h>
#include "local-include/reg.h"

const char *regs[] = {
  "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
  "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
  "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
};

void isa_reg_display_difftest(CPU_state *cpu, CPU_state *ref) {
    for(int i = 0; i < MUXDEF(CONFIG_RVE, 16, 32); i++) {
        printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
               (cpu->gpr[i] == ref->gpr[i]) ? ANSI_FG_GREEN : ANSI_FG_RED,
               regs[i], cpu->gpr[i], ref->gpr[i]);
    }
     printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
               (cpu->pc == ref->pc) ? ANSI_FG_GREEN : ANSI_FG_RED,
               "pc", cpu->pc, ref->pc);
}

void isa_reg_display() {
  int reg_number = MUXDEF(CONFIG_RVE, 16, 32);
  for(int i = 0; i < reg_number; i ++) {
    printf("%s值为%u\n",regs[i], cpu.gpr[i]);
  }
  printf("pc值为%u\n", cpu.pc);
}

word_t isa_reg_str2val(const char *s, bool *success) {
  int reg_number = MUXDEF(CONFIG_RVE, 16, 32);
  for(int i = 0; i < reg_number; i ++) {
    if(strcmp(s, regs[i]) == 0) {
      return cpu.gpr[i];
    }
  }
  if(strcmp(s, "pc") == 0) {
    return cpu.pc;
  }
  //提示
  Log("%s不是寄存器\n",s);
  assert(0);
  return 0;
}
