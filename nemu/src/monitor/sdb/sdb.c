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
void test_expr();
bool add_watchpoint(const char *expr);
void delete_watchpoint(int no);
void list_watchpoints();

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

static int cmd_help(char *args);

static int cmd_si(char *args) {
  int steps = 1;
  if (args != NULL) {
     if (sscanf(args, "%d", &steps) != 1){
        printf("Invalid argument. Usage: si [N]\n");
        return 0;
     };
  }
  cpu_exec(steps);
  return 0;
}

static int cmd_info(char *args) {
  if (args == NULL) {
    printf("Usage: info [r|w]\n");
    return 0;
  }
  if (strcmp(args, "r") == 0) {
    isa_reg_display();
  } else if (strcmp(args, "w") == 0) {
    list_watchpoints();
  } else {
    printf("Unknown subcommand '%s'. Usage: info [r|w]\n", args);
  }
  return 0;
}

static int cmd_w(char *args) {
  if (args == NULL) {
    printf("Usage: w EXPR\n");
    return 0;
  }
  if (add_watchpoint(args)) {
    printf("Watchpoint added successfully.\n");
  } else {
    printf("Failed to add watchpoint.\n");
  }
  return 0;
}

static int cmd_d(char *args) {
  if (args == NULL) {
    printf("Usage: d NO\n");
    return 0;
  }
  int no;
  if (sscanf(args, "%d", &no) != 1) {
    printf("Invalid argument. Usage: d NO\n");
    return 0;
  }
  delete_watchpoint(no);
  return 0;
}

static int cmd_x(char *args) {
  int n;
  vaddr_t addr;
  if (args == NULL || sscanf(args, "%d %x", &n, &addr) != 2) {
    printf("Invalid arguments. Usage: x N EXPR\n");
    return 0;
  }
  for (int i = 0; i < n; i++) {
    printf("0x%08x: 0x%08x\n", addr + i * 4, vaddr_read(addr + i * 4, 4));
  }
  return 0;
}


static int cmd_p(char *args) {
  if (args == NULL) {
    printf("Usage: p EXPR\n");
    return 0;
  }
  bool success;
  uint32_t result = expr(args, &success);
  if (success) {
    printf("Result: %u (0x%08x)\n", result, result);
  } else {
    printf("Failed to evaluate expression.\n");
  }
  return 0;
}

static int cmd_exprtest(char *args) {
  test_expr();
  return 0;
}

static struct {
  const char *name;
  const char *description;
  int (*handler) (char *);
} cmd_table [] = {
  { "help", "Display information about all supported commands", cmd_help },
  { "c", "Continue the execution of the program", cmd_c },
  { "q", "Exit NEMU", cmd_q },

  /* TODO: Add more commands */
  { "si", "Step one instruction exactly (or N instructions). Usage: si [N]", cmd_si },
  { "info", "Generic command for showing things about the program being debugged. Usage: info [r|w]", cmd_info },
  { "x", "Examine memory. Usage: x N EXPR", cmd_x },
  { "p", "Print the value of an expression. Usage: p EXPR", cmd_p },
  { "w", "Add a watchpoint. Usage: w EXPR", cmd_w },
  { "d", "Delete a watchpoint. Usage: d NO", cmd_d },
  { "exprtest", "Run generated expression tests from tools/gen-expr/input", cmd_exprtest },
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

#ifdef CONFIG_DEVICE
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
