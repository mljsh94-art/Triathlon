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

#include <cpu/cpu.h>
#include <cpu/decode.h>
#include <cpu/difftest.h>
#include <locale.h>
#include <elf.h>
#include <unistd.h>

/* The assembly code of instructions executed is only output to the screen
 * when the number of instructions executed is less than this value.
 * This is useful when you use the `si' command.
 * You can modify this value as you want.
 */
#define MAX_INST_TO_PRINT 10

CPU_state cpu = {};
uint64_t g_nr_guest_inst = 0;
static uint64_t g_timer = 0; // unit: us
static bool g_print_step = false;

void device_update();
extern bool scanf_wp();
static void trace_and_difftest(Decode *_this, vaddr_t dnpc) {
#ifdef CONFIG_ITRACE_COND
  if (ITRACE_COND) { log_write("%s\n", _this->logbuf); }
#endif
  if (g_print_step) { IFDEF(CONFIG_ITRACE, puts(_this->logbuf)); }
  IFDEF(CONFIG_DIFFTEST, difftest_step(_this->pc, dnpc));
  #ifdef CONFIG_CC_WP
    if(scanf_wp() == false) {
      nemu_state.state = NEMU_STOP;
    }
  #endif
}

#define IRINGBUF_SIZE 16
typedef struct {
    word_t pc;
    char log[128];
} IRingBufEntry;

typedef struct {
    IRingBufEntry entries[IRINGBUF_SIZE];
    int head; // 指向最早的有效条目
    int tail; // 指向下一个写入位置 
} IRingBuf;

static IRingBuf iringbuf;
void init_iringbuf() {
  iringbuf.head = 0;
  iringbuf.tail = 0;
}

void disply_iringbuf() {
  for(int i = iringbuf.head; i != iringbuf.tail; i = (i + 1) % IRINGBUF_SIZE) {
    printf("pc:%x:%s\n",iringbuf.entries[i].pc,iringbuf.entries[i].log);
  }
}

void add_iringbuf(int pc, char *p){
  if(((iringbuf.tail + 1) % IRINGBUF_SIZE) == iringbuf.head) //证明已经满了
  iringbuf.head = (iringbuf.head + 1) % IRINGBUF_SIZE; //删除第一个
  char *cur = iringbuf.entries[iringbuf.tail].log;
  iringbuf.entries[iringbuf.tail].pc = pc;
  strcpy(cur, p);
  iringbuf.tail = (iringbuf.tail + 1) % IRINGBUF_SIZE; //指向下一个写入位置
}

static void exec_once(Decode *s, vaddr_t pc) {
  s->pc = pc;
  s->snpc = pc;
  isa_exec_once(s);
  cpu.pc = s->dnpc;
}

static void execute(uint64_t n) {
  Decode s;
  for (;n > 0; n --) {
    exec_once(&s, cpu.pc);
    g_nr_guest_inst ++;
    trace_and_difftest(&s, cpu.pc);
    if (nemu_state.state != NEMU_RUNNING) break;
    IFDEF(CONFIG_DEVICE, device_update());
  }
}

static void statistic() {
  IFNDEF(CONFIG_TARGET_AM, setlocale(LC_NUMERIC, ""));
#define NUMBERIC_FMT MUXDEF(CONFIG_TARGET_AM, "%", "%'") PRIu64
  Log("host time spent = " NUMBERIC_FMT " us", g_timer);
  Log("total guest instructions = " NUMBERIC_FMT, g_nr_guest_inst);
  if (g_timer > 0) Log("simulation frequency = " NUMBERIC_FMT " inst/s", g_nr_guest_inst * 1000000 / g_timer);
  else Log("Finish running in less than 1 us and can not calculate the simulation frequency");
}

void assert_fail_msg() {
  isa_reg_display();
  disply_iringbuf();
  statistic();
}

#define FUNC_SIZE 128
#define stack_SIZE 1024
typedef struct{
  char name[128];
  Elf32_Addr st_addr;
  Elf32_Word st_size;
}FUNEntry;

typedef struct{
  int cnt;
  FUNEntry Entry[FUNC_SIZE];
}FUN;

typedef struct{
  int end;
  Elf32_Addr st_addr;
}RASstack;

static FUN fun;
static RASstack rasstack;
void init_func() {
  fun.cnt = 0;
}

void init_stack() {
  rasstack.end = 0;
}
void find_fun(int npc) {
  for(int i = 0; i < fun.cnt; i ++) {
    if(npc - fun.Entry[i].st_addr < fun.Entry[i].st_size){
      printf("%s\n",fun.Entry[i].name);
    }
  }
}

void RAS_stack(int pc, int npc, int rs1, int rd) {
  #ifdef CONFIG_FTRACE
    if((rs1 == 1 || rs1 == 5) && (rd == 1 || rd == 5) && (rs1 == rd)) {
      printf("cur pc :%x call %x",pc,npc);
      printf(" go :");
      find_fun(npc);
    }
    else if((rs1 == 1 || rs1 == 5) && (rd == 1 || rd == 5) && (rs1 != rd)){
      printf("cur pc :%x ret %x",pc,npc);
      printf(" go :");
      find_fun(npc);
    }
    else if(rs1 == 1 || rs1 == 5) {
      printf("cur pc :%x ret %x",pc,npc);
      printf(" go :");
      find_fun(npc);
    }
    else if(rd == 1 || rd == 5) {
      printf("cur pc :%x call %x",pc,npc);
      printf(" go :");
      find_fun(npc);
    }
  #endif
}

void init_elf(const char *filename) {
  //printf("%s\n",filename);
  FILE *file = fopen(filename, "rb");  // Changed to FILE*
  if (!file) { perror("fopen"); return; }

  Elf32_Ehdr ehdr;
  if (fread(&ehdr, sizeof(ehdr), 1, file) != 1) {  // Changed to fread
    panic("ELF文件不存在");
  }
  // {{ 1. 定位节头表 }}
  if (fseek(file, ehdr.e_shoff, SEEK_SET)) {  // Changed to fseek
    panic("定位节头表错误");
  }
  Elf32_Shdr shdr[ehdr.e_shnum];
  if (fread(shdr, sizeof(Elf32_Shdr), ehdr.e_shnum, file) != ehdr.e_shnum) {
    panic("读取节头错误");
  }
  //{{ 加载 .shstrtab }}
  Elf32_Shdr *shstrtab_hdr = &shdr[ehdr.e_shstrndx];
  char *shstrtab = malloc(shstrtab_hdr->sh_size);
  if(fseek(file, shstrtab_hdr->sh_offset, SEEK_SET)) {
    panic("定位失败");
  }
  if(fread(shstrtab, shstrtab_hdr->sh_size,1 , file) != 1) {
    panic("读取失败");
  }
  Elf32_Shdr *symtab = NULL, *strtab = NULL;
  for (int i = 0; i < ehdr.e_shnum; i++) {
      if (shdr[i].sh_type == SHT_SYMTAB) symtab = &shdr[i];
      if (shdr[i].sh_type == SHT_STRTAB && 
        strcmp(&shstrtab[shdr[i].sh_name], ".strtab") == 0) {  // 明确匹配符号字符串表
      strtab = &shdr[i];
    }
  }
// {{ 3. 读取符号表数据 }}
  Elf32_Sym *syms = malloc(symtab->sh_size);
  if (fseek(file, symtab->sh_offset, SEEK_SET)) { 
    panic("定位符号表错误");
  }
  if (fread(syms, symtab->sh_size, 1, file) != 1) { 
    panic("读取符号表错误");
  }
// {{ 4. 读取字符串表 }}
  char *strs = malloc(strtab->sh_size);
  if (fseek(file, strtab->sh_offset, SEEK_SET)) { 
    panic("定位字符串表错误");
  }
  if (fread(strs, strtab->sh_size, 1, file) != 1) {
    panic("读取字符串错误");
  }
// {{ 5. 遍历符号表 }
  //初始化函数
  init_func();
  //初始化RAS
  init_stack();
  for (int i = 0; i < symtab->sh_size / sizeof(Elf32_Sym); i++) {
    if((syms[i].st_info & 0xf) == 2) {
      strcpy(fun.Entry[fun.cnt].name, &strs[syms[i].st_name]);
      fun.Entry[fun.cnt].st_size = syms[i].st_size;
      fun.Entry[fun.cnt].st_addr = syms[i].st_value;
      fun.cnt ++;
    }
  }
  free(syms);
  free(strs);
  fclose(file);
}

/* Simulate how the CPU works. */

void cpu_exec(uint64_t n) {
  g_print_step = (n < MAX_INST_TO_PRINT);
  switch (nemu_state.state) {
    case NEMU_END: case NEMU_ABORT: case NEMU_QUIT:
      printf("Program execution has ended. To restart the program, exit NEMU and run again.\n");
      return;
    default: nemu_state.state = NEMU_RUNNING;
  }

  uint64_t timer_start = get_time();

  execute(n);

  uint64_t timer_end = get_time();
  g_timer += timer_end - timer_start;
 
  switch (nemu_state.state) {
    case NEMU_RUNNING: nemu_state.state = NEMU_STOP; break;

    case NEMU_END: case NEMU_ABORT:
      Log("nemu: %s at pc = " FMT_WORD,
          (nemu_state.state == NEMU_ABORT ? ANSI_FMT("ABORT", ANSI_FG_RED) :
           (nemu_state.halt_ret == 0 ? ANSI_FMT("HIT GOOD TRAP", ANSI_FG_GREEN) :
            ANSI_FMT("HIT BAD TRAP", ANSI_FG_RED))),
          nemu_state.halt_pc);
      // fall through
    case NEMU_QUIT: statistic();
  }
}
