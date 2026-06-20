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

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// this should be enough
static char buf[65536] = {};
static char *buf_p = buf;
static char *buf_end = buf + sizeof(buf);


static inline uint32_t choose(uint32_t n) {
  return rand() % n;
}

#define MAX_DEPTH 8
#define MAX_RETRY 1000

static bool append(const char *s) {
  size_t len = strlen(s);
  if (buf_p + len >= buf_end) {
    return false;
  }
  memcpy(buf_p, s, len);
  buf_p += len;
  *buf_p = '\0';
  return true;
}

static bool gen_spaces() {
  int n = choose(4);
  while (n-- > 0) {
    if (!append(" ")) {
      return false;
    }
  }
  return true;
}

static bool gen_num(uint32_t *val) {
  char num[32];
  *val = choose(UINT32_MAX);
  snprintf(num, sizeof(num), "%u", *val);
  return gen_spaces() && append(num) && gen_spaces();
}

static bool gen_rand_expr_recursive(int depth, uint32_t *val) {
  if (depth >= MAX_DEPTH) {
    return gen_num(val);
  }

  switch (choose(3)) {
    case 0:
      return gen_num(val);

    case 1:
      return gen_spaces()
          && append("(")
          && gen_rand_expr_recursive(depth + 1, val)
          && append(")")
          && gen_spaces();

    default: {
      uint32_t val1 = 0;
      uint32_t val2 = 0;
      char op = "+-*/"[choose(4)];

      if (!gen_spaces()
          || !append("(")
          || !gen_rand_expr_recursive(depth + 1, &val1)
          || !gen_spaces()
          || !append((char []){op, '\0'})
          || !gen_spaces()
          || !gen_rand_expr_recursive(depth + 1, &val2)
          || !append(")")
          || !gen_spaces()) {
        return false;
      }

      switch (op) {
        case '+': *val = val1 + val2; return true;
        case '-': *val = val1 - val2; return true;
        case '*': *val = val1 * val2; return true;
        case '/':
          if (val2 == 0) {
            return false;
          }
          *val = val1 / val2;
          return true;
        default: assert(0);
      }
    }
  }
}

static bool gen_rand_expr(uint32_t *val) {
  buf[0] = '\0';
  buf_p = buf;
  return gen_rand_expr_recursive(0, val);
}

int main(int argc, char *argv[]) {
  int seed = time(0);
  srand(seed);
  int loop = 1;
  if (argc > 1) {
    sscanf(argv[1], "%d", &loop);
  }
  int i;
  for (i = 0; i < loop; i ++) {
    uint32_t result = 0;
    int retry = 0;
    while (!gen_rand_expr(&result)) {
      retry++;
      if (retry > MAX_RETRY) {
        fprintf(stderr, "failed to generate a valid expression\n");
        return 1;
      }
    }

    printf("%u %s\n", result, buf);
  }
  return 0;
}
