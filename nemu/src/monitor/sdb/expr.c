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
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <regex.h>
#include <assert.h>

enum {
  TK_NOTYPE = 256, 
  TK_EQ,
  TK_NUM,
  TK_HEX,
  TK_REG,
  TK_NEQ,
  TK_AND,
  TK_OR,
  TK_DEREF,
  TK_NEG,
  TK_LE,  
  TK_GE,
  TK_LT,
  TK_GT


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
  {"\\+", '+'},         // plus
  {"\\-", '-'},         // minus
  {"\\*", '*'},         // multiply
  {"/", '/'},           // divide
  {"\\(", '('},         // left parenthesis
  {"\\)", ')'},         // right parenthesis
  {"0[xX][0-9a-fA-F]+", TK_HEX}, // hexadecimal number
  {"[0-9]+", TK_NUM},   // decimal number
  {"\\$[a-zA-Z0-9]+", TK_REG},   // register
  {"!=", TK_NEQ},       // not equal
  {"&&", TK_AND},       // logical and
  {"\\|\\|", TK_OR},    // logical or (已修正转义)
  {"==", TK_EQ},        // equal
  {"<=", TK_LE},       // less than or equal
  {">=", TK_GE},       // greater than or equal
  {"<", TK_LT},        // less than
  {">", TK_GT},        // greater than

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
#define MAX_TOKENS 65536
static Token tokens[MAX_TOKENS] __attribute__((used)) = {};
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
          case TK_NOTYPE: break;
          default: 
          if (nr_token >= MAX_TOKENS) {
              printf("Error: Too many tokens (max %d)!\n", MAX_TOKENS);
              return false;
            }

            tokens[nr_token].type = rules[i].token_type;

            // 需要记录具体字符串的 token
            if (rules[i].token_type == TK_NUM || 
                rules[i].token_type == TK_HEX || 
                rules[i].token_type == TK_REG) {
              
              // 终极防御 2：防止单个 Token 字符串过长导致缓冲区溢出
              if (substr_len >= 32) {
                printf("Error: Token string too long!\n");
                return false;
              }
              strncpy(tokens[nr_token].str, substr_start, substr_len);
              tokens[nr_token].str[substr_len] = '\0';
            }
            nr_token++;
            break;;
        }

        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      assert(0);
      return false;
    }
  }

  return true;
}

static int check_parentheses(int p, int q) {
  if (tokens[p].type != '(' || tokens[q].type != ')') {
    return 0;
  }

  int count = 0;
  for (int i = p + 1; i < q; i++) {
    if (tokens[i].type == '(') {
      count++;
    } else if (tokens[i].type == ')') {
      if (count == 0) {
        return 0;
      }
      count--;
    }
  }

  return count == 0;
}

static int find_main_operator(int p, int q) {
  int main_op = -1;
  int min_precedence = 100; // 足够大的初始值
  int parentheses_count = 0;

  for (int i = p; i <= q; i++) {
    if (tokens[i].type == '(') {
      parentheses_count++;
    } else if (tokens[i].type == ')') {
      parentheses_count--;
    } else if (parentheses_count == 0) {
      int precedence = 0;
      switch (tokens[i].type) {
        case TK_OR: precedence = 1; break;
        case TK_AND: precedence = 2; break;
        case TK_EQ:
        case TK_NEQ: precedence = 3; break;
        case TK_LE:
        case TK_GE:
        case TK_LT:
        case TK_GT: precedence = 4; break;
        case '+':
        case '-': precedence = 5; break;
        case '*':
        case '/': precedence = 6; break;
        case TK_DEREF:
        case TK_NEG: precedence = 7; break;
        default: precedence = 100; break; // 非运算符
      }

      if (precedence < min_precedence || (precedence == min_precedence && precedence != 7)) {
        min_precedence = precedence;
        main_op = i;
      }
    }
  }

  return main_op;
}

static uint32_t eval(int p, int q, bool *success) {
  if(*success == false) {
    return 0;
  }
  if (p > q) {
    printf("Bad expression!\n");
    assert(0);
  } else if (p == q) {
    // 单个 token
    if (tokens[p].type == TK_NUM) {
      return strtoul(tokens[p].str, NULL, 10);
    } else if (tokens[p].type == TK_HEX) {
      return strtoul(tokens[p].str, NULL, 16);
    } else if (tokens[p].type == TK_REG) {
      // 处理寄存器
      // 这里假设寄存器名是 $eax, $ebx 等，实际情况可能需要调整
      char *reg_name = tokens[p].str + 1; // 去掉 '$' 前缀
      return isa_reg_str2val(reg_name, success);
    } else {
      printf("Unexpected token type: %d\n", tokens[p].type);
      assert(0);
    }
  } else if (check_parentheses(p, q)) {
    // 括号表达式
    return eval(p + 1, q - 1, success);
  } else {
    int op = find_main_operator(p, q);
    if (op == -1) {
      printf("No operator found in expression!\n");
      assert(0);
    }
    uint32_t val1 = 0;
    if (tokens[op].type != TK_NEG && tokens[op].type != TK_DEREF) {
       val1 = eval(p, op - 1, success);
    }
    uint32_t val2 = eval(op + 1, q, success);
    if (*success == false) {
      return 0;
    }

    switch (tokens[op].type) {
      case TK_OR: return val1 || val2;
      case TK_AND: return val1 && val2;
      case TK_EQ: return val1 == val2;
      case TK_NEQ: return val1 != val2;
      case TK_LE: return val1 <= val2;
      case TK_GE: return val1 >= val2;
      case TK_LT: return val1 < val2;
      case TK_GT: return val1 > val2;
      case '+': return val1 + val2;
      case '-': return val1 - val2;
      case '*': return val1 * val2;
      case '/': 
        if (val2 == 0) {
          printf("Error: Division by zero!\n");
          *success = false;
          return 0;
        }
        return val1 / val2;
      case TK_NEG: return -val2; // 负号
      case TK_DEREF: return vaddr_read(val2, 4); // 解引用
      default:
        printf("Unexpected operator type: %d\n", tokens[op].type);
        assert(0);
    }
  }
}

word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }
  *success = true;
  if(nr_token == 0) {
    printf("Error: Empty expression!\n");
    *success = false;
    return 0;
  }
  for (int i = 0; i < nr_token; i++) {
    if (tokens[i].type == '*' || tokens[i].type == '-') {
      // 满足以下任一条件就是一元运算符：
      // 1. 它是表达式的第一个符号
      // 2. 它前面不是数字、寄存器、或右括号 ')'
      if (i == 0 || (tokens[i - 1].type != TK_NUM && 
                     tokens[i - 1].type != TK_HEX && 
                     tokens[i - 1].type != TK_REG && 
                     tokens[i - 1].type != ')')) {
        
        if (tokens[i].type == '*') {
          tokens[i].type = TK_DEREF;
        } else {
          tokens[i].type = TK_NEG;
        }
      }
    }
  }
  /* TODO: Insert codes to evaluate the expression. */
  

  return eval(0, nr_token - 1, success);
}

void test_expr() {
  // 1. 打开你刚刚生成的 input 文件
  // 注意：NEMU 通常是在 nemu/ 目录下执行 make run 的，
  // 所以相对路径一般是下面这样。如果找不到，可以用绝对路径。
  FILE *fp = fopen("tools/gen-expr/build/input", "r");
  if (fp == NULL) {
    // 如果没找到文件，就静默返回，不影响正常的 NEMU 运行
    printf("[Warning] 'tools/gen-expr/build/input' not found. Skip expression testing.\n");
    return;
  }

  uint32_t expected_res;
  char expr_str[65536]; // 保证缓冲区足够大以容纳长表达式
  int count = 0;

  printf("Start testing expressions from input file...\n");

  // 2. 核心黑魔法：fscanf 的正则表达式读取
  // "%u"        : 读取开头的无符号整数结果
  // " "         : 匹配中间的空格
  // "%[^\n]"    : 一直读取字符，直到遇到换行符 '\n' 为止。这样就能把带有空格的完整表达式读进 expr_str 里！
  while (fscanf(fp, "%u %[^\n]", &expected_res, expr_str) == 2) {
    bool success;
    
    // 把读到的表达式扔给你写的 expr 函数去算
    uint32_t actual_res = expr(expr_str, &success);

    // 3. 严格对比
    if (success == false || actual_res != expected_res) {
      printf("\n[FAILED] Test case %d\n", count + 1);
      printf("Expression : %s\n", expr_str);
      printf("Expected   : %u\n", expected_res);
      printf("Actual     : %u\n", actual_res);
      if (success == false) {
        printf("Reason     : expr() returned success = false\n");
      }
      assert(0); // 遇到错误直接终止，逼着你去 debug
    }
    count++;
  }

  fclose(fp);
  printf("\033[1;32m[SUCCESS]\033[0m All %d expressions evaluated correctly!\n", count);
}
