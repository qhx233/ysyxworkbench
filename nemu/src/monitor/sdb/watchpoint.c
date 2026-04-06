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
#include <assert.h>

word_t expr(char *e, bool *success);
#define NR_WP 32

typedef struct watchpoint {
  int NO;
  struct watchpoint *next;

  char expr[128];
  uint32_t old_val;

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

/* TODO: Implement the functionality of watchpoint */

WP* new_wp() {
  if (free_ == NULL) {
    printf("No free watchpoint!\n");
    assert(0);
    return NULL;
  }

  WP *wp = free_;
  free_ = free_->next;
  wp->next = head;
  head = wp;

  wp->old_val = 0;
  wp->expr[0] = '\0';

  return wp;
}

void free_wp(WP *wp) {
  if (wp == NULL || head == NULL) return;
  
  if(head == wp) {
    head = head->next;
  } else {
    WP *prev = head;
    while (prev->next != NULL && prev->next != wp) {
      prev = prev->next;
    }
    assert(prev->next != wp); // Ensure that wp is in the list
    if (prev->next == wp) {
      prev->next = wp->next;
    }
  }

  wp->next = free_;
  free_ = wp;


}

bool add_watchpoint( char *expr_str) {
  WP *wp = new_wp();
  if (wp == NULL) return false;

  strncpy(wp->expr, expr_str, sizeof(wp->expr) - 1);
  wp->expr[sizeof(wp->expr) - 1] = '\0'; // Ensure null-termination

  bool success = true;
  wp->old_val = expr(expr_str, &success);
  if (!success) {
    printf("Failed to evaluate expression: %s\n", expr_str);
    free_wp(wp);
    return false;
  }
  printf("Watchpoint %d: %s (initial value: %u)\n", wp->NO, wp->expr, wp->old_val);
  return true;
}

bool check_watchpoints() {
  WP *wp = head;
  bool triggered = false;

  while (wp != NULL) {
    bool success = true;
    uint32_t new_val = expr(wp->expr, &success);
   if(new_val != wp->old_val) {
      printf("Watchpoint %d triggered: %s changed from %u to %u\n", wp->NO, wp->expr, wp->old_val, new_val);
      wp->old_val = new_val;
      triggered = true;
    }
    wp = wp->next;
  }
  return triggered;
}

void list_watchpoints() {
  WP *wp = head;
  if (wp == NULL) {
    printf("No watchpoints set.\n");
    return;
  }

  printf("Watchpoints:\n");
  while (wp != NULL) {
    printf("  %d: %s (current value: %u)\n", wp->NO, wp->expr, wp->old_val);
    wp = wp->next;
  }
}

void delete_watchpoint(int no) {
  WP *wp = head;
  while (wp != NULL) {
    if (wp->NO == no) {
      free_wp(wp);
      printf("Watchpoint %d deleted.\n", no);
      return;
    }
    wp = wp->next;
  }
  printf("Watchpoint %d not found.\n", no);
}