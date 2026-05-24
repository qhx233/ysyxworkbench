#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

extern void putch(char ch);
void debug_print_hex(const char *msg, uint32_t val) {
    while (*msg) putch(*msg++);
    putch('0'); putch('x');
    for (int i = 7; i >= 0; i--) {
        int hex = (val >> (i * 4)) & 0xF;
        putch(hex < 10 ? '0' + hex : 'a' + hex - 10);
    }
    putch('\n');
}

static Context* (*user_handler)(Event, Context*) = NULL;

Context* __am_irq_handle(Context *c) {
  if (user_handler) {
    Event ev = {0};
    debug_print_hex("[DEBUG] Context Size = ", sizeof(Context));
    debug_print_hex("[DEBUG] mcause       = ", c->mcause);
    debug_print_hex("[DEBUG] a5 (gpr[15]) = ", c->gpr[15]);
    // --- 调试打印开始 ---
    // 如果布局正确，mcause 应该是 11 (0xb)，mepc 应该是执行 ecall 时的 PC
    //printf("DEBUG: mcause = 0x%x, mepc = 0x%x, mstatus = 0x%x\n", 
            //c->mcause, c->mepc, c->mstatus);
    
    // 检查 a5 寄存器 (x15)，yield() 函数里执行了 li a5, -1
    // 如果布局正确，c->gpr[15] 应该是 0xffffffff
   // printf("DEBUG: gpr[15] (a5) = 0x%x\n", c->gpr[15]);
    // --- 调试打印结束 ---
    switch (c->mcause) {
      case 0xb:  // 十六进制的 11，代表 Environment call from M-mode
        // 判断 a7 (x17) 寄存器是不是 -1
        // 如果是 -1，说明这是我们通过 yield() 触发的自陷
     #ifdef __riscv_e
        if (c->gpr[15] == -1) { // RV32E: 检查 a5 (x15)
      #else
        if (c->gpr[17] == -1) { // RV32I: 检查 a7 (x17)
        #endif
          ev.event = EVENT_YIELD;
        } else {
          ev.event = EVENT_SYSCALL; 
        }
     
        // 【关键】跳过 ecall 指令，否则 mret 返回后会无限死循环执行 ecall
        c->mepc += 4;
        break;
      default: ev.event = EVENT_ERROR; break;
    }

    c = user_handler(ev, c);
    assert(c != NULL);
  }

  return c;
}

extern void __am_asm_trap(void);

bool cte_init(Context*(*handler)(Event, Context*)) {
  // initialize exception entry
  asm volatile("csrw mtvec, %0" : : "r"(__am_asm_trap));

  // register event handler
  user_handler = handler;

  return true;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg) {
  Context *c = (Context *)((uintptr_t)kstack.end - sizeof(Context));
  for(int i = 0; i < sizeof(Context)/ sizeof(uintptr_t);i++){
    ((uintptr_t*)c)[i] = 0;
  }
  c->mepc = (uintptr_t)entry;
  c->mstatus = 0x1800; // MPP = 11 (Machine Mode)
  c->gpr[10] = (uintptr_t)arg; // a0 = arg
  c->pdir = NULL;


  return c;
}

void yield() {
#ifdef __riscv_e
  asm volatile("li a5, -1; ecall");
#else
  asm volatile("li a7, -1; ecall");
#endif
}

bool ienabled() {
  return false;
}

void iset(bool enable) {
}
