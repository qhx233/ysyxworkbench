#include <am.h>
#include <klib-macros.h>

// ysyxSoC 的 UART16550 发送寄存器物理地址
#define SERIAL_PORT 0x10000000L

// 引入我们在 linker.ld 中定义的堆区范围
extern char _heap_start;
extern char _heap_end;

int main(const char *args);

// ysyxSoC 的堆区必须严格限制在 SRAM 内
Area heap = RANGE(&_heap_start, &_heap_end);

// 处理 mainargs 传参 (兼容 klib 宏)
#ifndef MAINARGS_PLACEHOLDER
#define MAINARGS_PLACEHOLDER ""
#endif
static const char mainargs[] = TOSTRING(MAINARGS_PLACEHOLDER);

void putch(char ch) {
  // 向串口发送字符
  *(volatile uint8_t *)SERIAL_PORT = ch;
}

void halt(int code) {
  // 规范写法：把程序的退出码 code 放进 a0 寄存器，然后 ebreak。
  // 这样你的 npc_trap(int a0_val) 就能精确识别是 GOOD TRAP 还是 BAD TRAP 了！
  asm volatile("mv a0, %0; ebreak" : : "r"(code));
  while (1);
}

void _trm_init() {
  // 跳转到 C 语言的 main 函数，并传入参数
  int ret = main(mainargs);
  // 程序结束，将 main 的返回值传给 halt
  halt(ret);
}