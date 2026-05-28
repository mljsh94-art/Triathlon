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

#include "sdb.h"

#define NR_WP 32
typedef struct watchpoint {
  int NO; //编号
  struct watchpoint *next; //指针
  char str[65536]; //表达式
  word_t number; //数值 
  /* TODO: Add more members if necessary */
} WP;

static WP wp_pool[NR_WP] = {};
static WP *head = NULL, *free_ = NULL;

void init_wp_pool() {
  int i;
  for (i = 0; i < NR_WP; i ++) {
    wp_pool[i].NO = i;
    wp_pool[i].next = (i == NR_WP - 1 ? NULL : &wp_pool[i + 1]);
  }

  head = NULL;
  free_ = wp_pool;
}

WP* new_wp() {
  if(free_ == NULL) {
    Log("监视点个数不够");
    assert(0);
  }
  WP *n_wp = free_;
  free_ = free_->next;
  return n_wp;
}

void free_wp(WP *wp) {
  wp->next = free_;
  free_ = wp;
}
void add_wp(char *e) {
  WP *n_wp = new_wp();
  if(head == NULL) {
    n_wp->next = NULL;
    head = n_wp;
  }
  else {
    n_wp->next = head;
    head = n_wp;
  }
  bool success;
  head->number = expr(e, &success);
  int len = strlen(e);
  for(int i = 0; i < len; i ++) {
    head->str[i] = *(e + i);
  }
  head->str[len] = '\0';
}

void delete_wp(int d_NO) {
  WP *cur = head;
  WP *pre_cur = NULL;
  while(cur->NO != d_NO) {
    pre_cur = cur;
    cur = cur->next;
  }
  if(cur == head) {
    head = head->next;
    free_wp(cur);
  }
  else {
    pre_cur->next = cur->next;
    free_wp(cur);
  }
}

void display_wp() {
  WP *cur = head;
  while(cur != NULL) {
    printf("监视点%d处---------表达式为%s---------值为%u\n",cur->NO,cur->str,cur->number);
    cur = cur->next;
  }
}

bool scanf_wp() {
  bool ok = 1;
  WP *cur = head;
  while(cur != NULL) {
    bool success;
    int n_number = expr(cur->str, &success);
    if(n_number != cur->number) {
      printf("监视点%d处---------表达式为%s---------旧值为%u---------新值为%u\n",cur->NO,cur->str,cur->number,n_number);
      ok = 0;
    }
    cur->number = n_number;
    cur = cur->next;
  }
  return ok;
}
