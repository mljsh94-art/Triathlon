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
#include <cpu/cpu.h>
#include <readline/readline.h>
#include <readline/history.h>
#include "sdb.h"
#include <memory/vaddr.h>

static int is_batch_mode = false;

void init_regex();
void init_wp_pool();

/* We use the `readline' library to provide more flexibility to read from stdin. */
static char* rl_gets() {
  static char *line_read = NULL;

  if (line_read) {
    free(line_read);
    line_read = NULL;
  }

  line_read = readline("(nemu) ");

  if (line_read && *line_read) {
    add_history(line_read);
  }

  return line_read;
}

static int cmd_c(char *args) {
  cpu_exec(-1);
  return 0;
}

static int cmd_q(char *args) {
  nemu_state.state = NEMU_QUIT;
  return -1;
}
static int cmd_si(char *args){
  unsigned int execute_number;
  if(args == NULL) 
    execute_number = 1;
  else 
    execute_number = strtol(args, NULL, 10);;
  //atoi 把字符串转变为数字
  cpu_exec(execute_number);
  return 0;
}
static int cmd_info(char *args){
  if(strcmp(args, "r") == 0){
    isa_reg_display();
  }
  else if(strcmp(args, "w") == 0){
    display_wp();
  }
  else {
    printf("未知命令\n");
  }
  return 0;
}
static int cmd_expr(char *args) {
  bool success;
  unsigned int e_sum = expr(args, &success);
  printf("%u\n",e_sum);
  return success;
}
static int cmd_w(char *args) {
  add_wp(args);
  return 0;
}
static int cmd_dw(char *args) {
  delete_wp(strtol(args, NULL, 10));
  return 0;
}
static int cmd_x(char *args){
  printf("%s\n",args);
  char* token = strtok(args, " ");
  unsigned int x_number = strtol(token, NULL, 10);
  token = strtok(NULL, " ");
  unsigned int x_start = strtol(token, NULL, 16);
  for(int i = 0; i < x_number; i ++) {
    printf("%lx处的值为%08x\n",x_start + i * sizeof(word_t), vaddr_read(x_start + i * sizeof(word_t), sizeof(word_t)));
  }
  return 0;
}

static int cmd_expr_test(char *args) {
  FILE *fp = fopen("/home/xuxubaobao/Desktop/ysyx-workbench/nemu/tools/gen-expr/input", "r");
  if (fp == NULL){ 
    printf("文件不存在");
    return 0;
  }
  char *e = NULL;
  word_t correct_res;
  size_t len = 0;
  ssize_t read;
  bool success = true;

  while (true) {
    if(fscanf(fp, "%u ", &correct_res) == -1) break;
    read = getline(&e, &len, fp);
    e[read-1] = '\0';
    
    printf("%s\n",e);
    word_t res = expr(e, &success);
    assert(success);
    if (res != correct_res) {
      puts(e);
      printf("expected: %u, got: %u\n", correct_res, res);
      assert(0);
    }
  }

  fclose(fp);
  if (e) free(e);

  Log("expr test pass");
  return 1;
}

static int cmd_help(char *args);

static struct {
  const char *name;
  const char *description;
  int (*handler) (char *);
} cmd_table [] = {
  { "help", "Display information about all supported commands", cmd_help },
  { "c", "Continue the execution of the program", cmd_c },
  { "q", "Exit NEMU", cmd_q },
  { "si", "Step execution", cmd_si },
  { "info", "infomation", cmd_info },
  { "x", "scanf memory", cmd_x},
  { "expr", "print EXPR", cmd_expr},
  {"expr_test", "test expr module", cmd_expr_test},
  {"w", "add watch point", cmd_w},
  {"d", "delete watch point", cmd_dw},

  /* TODO: Add more commands */

};

#define NR_CMD ARRLEN(cmd_table)

static int cmd_help(char *args) {
  /* extract the first argument */
  char *arg = strtok(NULL, " ");
  int i;

  if (arg == NULL) {
    /* no argument given */
    for (i = 0; i < NR_CMD; i ++) {
      printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
    }
  }
  else {
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(arg, cmd_table[i].name) == 0) {
        printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
        return 0;
      }
    }
    printf("Unknown command '%s'\n", arg);
  }
  return 0;
}

void sdb_set_batch_mode() {
  is_batch_mode = true;
}

void sdb_mainloop() {
  if (is_batch_mode) {
    cmd_c(NULL);
    return;
  }

  for (char *str; (str = rl_gets()) != NULL; ) {
    char *str_end = str + strlen(str);

    /* extract the first token as the command */
    char *cmd = strtok(str, " ");
    if (cmd == NULL) { continue; }

    /* treat the remaining string as the arguments,
     * which may need further parsing
     */
    char *args = cmd + strlen(cmd) + 1;
    if (args >= str_end) {
      args = NULL;
    }

#if defined(CONFIG_DEVICE) && defined(CONFIG_HAS_VGA)
    extern void sdl_clear_event_queue();
    sdl_clear_event_queue();
#endif

    int i;
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(cmd, cmd_table[i].name) == 0) {
        if (cmd_table[i].handler(args) < 0) { return; }
        break;
      }
    }

    if (i == NR_CMD) { printf("Unknown command '%s'\n", cmd); }
  }
}

void init_sdb() {
  /* Compile the regular expressions. */
  init_regex();

  /* Initialize the watchpoint pool. */
  init_wp_pool();
}
