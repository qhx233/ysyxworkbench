#ifndef ARCH_H__
#define ARCH_H__

#ifdef __riscv_e
#define NR_REGS 16
#else
#define NR_REGS 32
#endif

struct Context {
  // TODO: fix the order of these members to match trap.S
  uintptr_t gpr[NR_REGS];

  // 接下来是偏移量为 NR_REGS * XLEN 的地方
  uintptr_t mcause;   // OFFSET_CAUSE
  uintptr_t mstatus;  // OFFSET_STATUS
  uintptr_t mepc;     // OFFSET_EPC

  // 最后的 pdir 占位（根据代码，如果你在汇编里没存 pdir，
  // 也可以把 pdir 放在 gpr[0] 的位置，这取决于 PA4 的具体实现）
  void *pdir;
};

#ifdef __riscv_e
#define GPR1 gpr[15] // a5
#else
#define GPR1 gpr[17] // a7
#endif

#define GPR2 gpr[0]
#define GPR3 gpr[0]
#define GPR4 gpr[0]
#define GPRx gpr[0]

#endif
