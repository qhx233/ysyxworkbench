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

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <assert.h>
#include <string.h>

// this should be enough
static char buf[65536] = {};
static char code_buf[65536 + 128] = {}; // a little larger than `buf`
static char *code_format =
"#include <stdio.h>\n"
"int main() { "
"  unsigned result = %s; "
"  printf(\"%%u\", result); "
"  return 0; "
"}";


static inline uint32_t choose(uint32_t n) {
  return rand() % n;
}

#define MAX_DEPTH 3
static int current_depth = 0;

// 递归生成主体
static void gen_rand_expr_recursive() {
  if (current_depth > MAX_DEPTH) {
    // 达到最大深度，强制生成纯数字（1到100）
    sprintf(buf + strlen(buf), "%u", choose(100) + 1);
    return;
  }

  current_depth++;

  switch (choose(3)) {
    case 0: 
      sprintf(buf + strlen(buf), "%u", choose(100) + 1);
      break;

    case 1: 
      sprintf(buf + strlen(buf), "(");
      // 随机插入空格，疯狂测试你写的 make_token 健壮性
      for (int i = 0; i < choose(3); i++) sprintf(buf + strlen(buf), " ");
      
      gen_rand_expr_recursive();
      
      for (int i = 0; i < choose(3); i++) sprintf(buf + strlen(buf), " ");
      sprintf(buf + strlen(buf), ")");
      break;

    default: 
      gen_rand_expr_recursive();
      
      // 注意：这里故意移除了除号 '/' !
      // 因为随机生成的表达式极容易出现除以 0，这会导致 gcc 编译后的程序运行时触发 SIGFPE 崩溃，
      // 进而导致 popen 读不到数据，中断整个测试过程。先用加减乘保证框架能跑通。
      char op = "*-+"[choose(3)]; 
      
      sprintf(buf + strlen(buf), " %c ", op);
      
      gen_rand_expr_recursive();
      break;
  }

  current_depth--;
}


static void gen_rand_expr() {
  buf[0] = '\0';
  current_depth = 0;
  gen_rand_expr_recursive();
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
    gen_rand_expr();

    sprintf(code_buf, code_format, buf);

    FILE *fp = fopen("/tmp/.code.c", "w");
    assert(fp != NULL);
    fputs(code_buf, fp);
    fclose(fp);

    int ret = system("gcc /tmp/.code.c -o /tmp/.expr");
    if (ret != 0) continue;

    fp = popen("/tmp/.expr", "r");
    assert(fp != NULL);

    int result;
    ret = fscanf(fp, "%d", &result);
    pclose(fp);

    printf("%u %s\n", result, buf);
  }
  return 0;
}
