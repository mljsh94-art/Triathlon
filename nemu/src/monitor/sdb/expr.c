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
#include <memory/vaddr.h>

/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <regex.h>

enum {
  TK_NOTYPE = 256, // 空格   
  TK_NUMBER10 = 1, //十进制数
  TK_PLUS = 2, // 加法
  TK_SUB = 3, // 减法
  TK_MUL = 4, // 乘法
  TK_DIV = 5, // 除法
  TK_NUMBER16 = 6, //十六进制数
  TK_left = 7, // 左括号
  TK_righ = 8, // 右括号
  TK_EQ = 9,   // ==
  TK_NE = 10,  // != 
  TK_REG = 11, // $
  TK_AND = 12, // &&
  TK_De = 13, //解引用
  /* TODO: Add more token types */

};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {

  /* TODO: Add more rules.
   * Pay attention to the precedence level of different rules.
   */

  {" +", TK_NOTYPE},    // spaces
  {"\\+", TK_PLUS},         // plus
  {"==", TK_EQ},        // equal
  {"!=", TK_NE},        // not equal
  {"&&", TK_AND},       // and
  {"\\-", TK_SUB},      //sub
  {"\\*", TK_MUL},      //乘 or 引用
  {"\\/", TK_DIV},      //div
  {"\\$.{2}", TK_REG},    //寄存器
  {"\\(", TK_left},      //left (
  {"\\)", TK_righ},      //righ )
  {"0[xX][0-9A-Fa-f]+", TK_NUMBER16}, // number -16
  {"[0-9]+u?", TK_NUMBER10}, // number -10
};

#define NR_REGEX ARRLEN(rules)

static regex_t re[NR_REGEX] = {};

/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
void init_regex() {
  int i;
  char error_msg[128];
  int ret;

  for (i = 0; i < NR_REGEX; i ++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[32];
} Token;
static Token tokens[65536] __attribute__((used)) = {};
static int nr_token __attribute__((used))  = 0;

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;

  nr_token = 0;

  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s",
            i, rules[i].regex, position, substr_len, substr_len, substr_start);

        position += substr_len;

        /* TODO: Now a new token is recognized with rules[i]. Add codes
         * to record the token in the array `tokens'. For certain types
         * of tokens, some extra actions should be performed.
         */
        switch (rules[i].token_type) {
          //括号匹配
          case TK_left: // (
          case TK_righ: // )
          {
            tokens[nr_token].type = rules[i].token_type;
            for(int i = 0; i < substr_len; i ++) {
              tokens[nr_token].str[i] = *(substr_start + i);
            }
            tokens[nr_token].str[substr_len] = '\0';
            nr_token++;
            break;
          }
          //运算符
          case TK_AND: // &&
          case TK_REG: // $
          case TK_EQ:  // ==
          case TK_NE:  // !=
          case TK_MUL: // *
          case TK_DIV: // /
          case TK_SUB: // -
          case TK_PLUS:// +
          {
            tokens[nr_token].type = rules[i].token_type;
            for(int i = 0; i < substr_len; i ++) {
              tokens[nr_token].str[i] = *(substr_start + i);
            }
            tokens[nr_token].str[substr_len] = '\0';
            nr_token++;
            break;
          }
          //数字
          case TK_NUMBER16: // 十进制数
          case TK_NUMBER10: // 十六进制数
          {
            tokens[nr_token].type = rules[i].token_type;
            for(int i = 0; i < substr_len; i ++) {
              tokens[nr_token].str[i] = *(substr_start + i);
            }
            tokens[nr_token].str[substr_len] = '\0';
            nr_token++;
            break;
          }
          case TK_NOTYPE: // 空格
          {
            break;
          }
          default: TODO();
        }
        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }
  for(int i = 0; i < nr_token; i ++) {
    printf("%s ", tokens[i].str);
  }
  printf("\n");
  return true;
}

bool check_parentheses(int l, int r) {
  bool check = 1;
  int lp = 0;
  for(int i = l + 1; i <= r - 1; i ++) {
    if(tokens[i].type == TK_left) lp ++;
    if(tokens[i].type == TK_righ) lp --;
    check = (lp < 0) ? 0 : check;
  }
  check = (lp == 0) & (tokens[l].type == TK_left) & (tokens[r].type == TK_righ) ? check : 0;
  return check;
}
unsigned int eval(int l, int r) {
  if(l > r) { //处理解引用 * - $的时候可能越界
    return 0;
  }
  if(l == r) {
    unsigned int number = 0;
    if(tokens[l].type == TK_NUMBER16) number = strtol(tokens[l].str, NULL, 16);
    else if(tokens[l].type == TK_NUMBER10) number = strtol(tokens[l].str, NULL, 10);
    else if(tokens[l].type == TK_REG) number = isa_reg_str2val(tokens[l].str + 1, NULL);
    return number;
  }
  else if(check_parentheses(l, r) == true){
    return eval(l + 1, r - 1);
  }
  else {
    //寻找主运算符
    int pos = 0;
    int level = -1;
    //level: && :4      == =!: 3
    //level: + - : 2    * / : 1
    //level: * - $ : 0 
    // && ----> ==  != ==  -----> + -  -----> * / -----> *解引用  -负号
    int lp = 0;
    //如果当前在括号里面，不参与运算
    for(int i = l; i <= r; i ++) {
      if(tokens[i].type == TK_left) lp ++;
      if(tokens[i].type == TK_righ) lp --;
      if(lp == 0){
        int cur_level;
        switch (tokens[i].type)
        {
          case TK_AND: // &&
            cur_level = 4;
            break;
          case TK_EQ: // ==
          case TK_NE: // !=
            cur_level = 3;
            break;
          case TK_PLUS:// +
          case TK_SUB :// -
            cur_level = 2;
            break;
          case TK_DIV:// *
          case TK_MUL:// /
            cur_level = 1;
            break;
          case TK_De : //解引用 *
            cur_level = 0;
            break;
          default:
            cur_level = -1;
            break;
        }
        if(cur_level >= level) pos = i, level = cur_level;
      }
    }
    unsigned l_num = eval(l, pos - 1);
    unsigned r_num = eval(pos + 1, r);
    unsigned e_sum = 0;
    //处理运算符
    switch (tokens[pos].type)
      {
        case TK_NE: {
          e_sum = (l_num != r_num);
          break;
        }
        case TK_EQ: {
          e_sum = (l_num == r_num);
          break;
        }
        case TK_De: {
          e_sum = vaddr_read(r_num, sizeof(word_t));
          break;
        }
        case TK_AND:{
          e_sum = l_num && r_num;
          break;
        }
        case TK_PLUS:{
          e_sum = l_num + r_num;
          break;
        }
        case TK_SUB :{
          e_sum = l_num - r_num;
          break;
        }
        case TK_DIV:{
          e_sum = l_num / r_num;
          break;
        }
        case TK_MUL:{
          e_sum = l_num * r_num;
          break;
        }
      }
    return e_sum;
  }
}

word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }
  //判断*是不是乘法或者解引用
  //如果*前面是 运算符 / ( 都是解引用
  //不可能是数字和)
  //所以数字和)的都是乘法其他情况下均是解引用
  for(int i = 0; i < nr_token; i ++) {
    if(tokens[i].type == TK_MUL && (i == 0 || ((tokens[i - 1].type != TK_righ) && (tokens[i - 1].type != TK_NUMBER10) && (tokens[i - 1].type != TK_NUMBER16)))) {
      tokens[i].type = TK_De;
      printf("%d\n",i);
    }
  }
  /* evaluate the expression. */
  return eval(0, nr_token - 1);
}
