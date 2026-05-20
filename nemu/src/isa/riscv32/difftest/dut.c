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
#include <cpu/difftest.h>
#include "../local-include/reg.h"
extern const char *regs[];
bool isa_difftest_checkregs(CPU_state *ref_r, vaddr_t pc) {
  if (cpu.pc != ref_r->pc) {
      Log("DiffTest failed: PC mismatch at pc = " FMT_PADDR, pc);
      Log("NEMU PC: " FMT_PADDR " | REF PC: " FMT_PADDR, cpu.pc, ref_r->pc);
      return false;
  }

  // 2. 遍历检查 32 个通用寄存器
  for (int i = 0; i < 32; i++) {
      if (cpu.gpr[i] != ref_r->gpr[i]) {
          Log("DiffTest failed: Register [%s] mismatch at pc = " FMT_PADDR, regs[i], pc);
          Log("NEMU %s: 0x%08x | REF %s: 0x%08x", regs[i], cpu.gpr[i], regs[i], ref_r->gpr[i]);
          return false;
      }
  }

  // 如果全部一致，返回 true，放行下一条指令
  return true;
}

void isa_difftest_attach() {
}
