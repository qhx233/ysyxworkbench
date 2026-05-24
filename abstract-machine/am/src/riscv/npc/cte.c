/*#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

static Context* (*user_handler)(Event, Context*) = NULL;

Context* __am_irq_handle(Context *c) {
  if (user_handler) {
    Event ev = {0};
    switch (c->mcause) {
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
  return NULL;
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
}*/
#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

static Context* (*user_handler)(Event, Context*) = NULL;

Context* __am_irq_handle(Context *c) {
  if (user_handler) {
    Event ev = {0};
    
    switch (c->mcause) {
      case 11: // 0xb: Environment call from M-mode (由 ecall 触发)
#ifdef __riscv_e
        // RV32E 没有 a7，使用 a5 (x15) 传递系统调用号
        if (c->gpr[15] == -1) {
#else
        // 标准 RV32I 使用 a7 (x17)
        if (c->gpr[17] == -1) {
#endif
          ev.event = EVENT_YIELD;
        } else {
          ev.event = EVENT_SYSCALL;
        }
        // 【关键】：必须将 mepc + 4，跳过这条 ecall 指令
        // 否则 mret 返回后，又会执行一次 ecall，陷入死循环
        c->mepc += 4;
        break;

      default: 
        ev.event = EVENT_ERROR; 
        break;
    }

    c = user_handler(ev, c);
    assert(c != NULL);
  }

  return c;
}

extern void __am_asm_trap(void);

bool cte_init(Context*(*handler)(Event, Context*)) {
  // 初始化异常入口地址 (填入 mtvec 寄存器)
  asm volatile("csrw mtvec, %0" : : "r"(__am_asm_trap));

  // 注册操作系统级别的事件处理回调函数
  user_handler = handler;

  return true;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg) {
  // 1. 在分配的栈区最底部（高地址），划分出一块 Context 结构体大小的空间
  Context *c = (Context *)((uintptr_t)kstack.end - sizeof(Context));

  // 2. 将这块内存清零，防止残留数据干扰寄存器
  for (int i = 0; i < sizeof(Context) / sizeof(uintptr_t); i++) {
    ((uintptr_t *)c)[i] = 0;
  }

  // 3. 设置入口地址 (mret 返回时，PC 会跳到这里)
  c->mepc = (uintptr_t)entry;

  // 4. 设置机器模式状态 (MPP = 11 表示 M-mode)
  c->mstatus = 0x1800;

  // 5. 设置参数 (RISC-V 规定第一个参数存放在 a0 寄存器，即 x10)
  c->gpr[10] = (uintptr_t)arg;
  
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
