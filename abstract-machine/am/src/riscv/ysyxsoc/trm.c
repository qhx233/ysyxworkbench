#include <am.h>
#include <klib-macros.h>

#define UART_BASE 0x10000000L
#define UART_TX   0
#define UART_IER  1
#define UART_FCR  2
#define UART_LCR  3
#define UART_LSR  5
#define UART_LSR_THRE 0x20

extern char _heap_start;
extern char _heap_end;
extern char _data_load_start;
extern char _data_start;
extern char _data_end;
extern char _bss_start;
extern char _bss_end;

int main(const char *args);

Area heap = RANGE(&_heap_start, &_heap_end);

// 处理 mainargs 传参 (兼容 klib 宏)
#ifndef MAINARGS_PLACEHOLDER
#define MAINARGS_PLACEHOLDER ""
#endif
static const char mainargs[] = TOSTRING(MAINARGS_PLACEHOLDER);

static inline void outb(uintptr_t addr, uint8_t data) {
  *(volatile uint8_t *)addr = data;
}

static inline uint8_t inb(uintptr_t addr) {
  return *(volatile uint8_t *)addr;
}

static void uart_init() {
  outb(UART_BASE + UART_IER, 0x00);
  outb(UART_BASE + UART_LCR, 0x80);
  outb(UART_BASE + 0, 0x01);
  outb(UART_BASE + 1, 0x00);
  outb(UART_BASE + UART_LCR, 0x03);
  outb(UART_BASE + UART_FCR, 0x07);
}

void putch(char ch) {
  while ((inb(UART_BASE + UART_LSR) & UART_LSR_THRE) == 0);
  outb(UART_BASE + UART_TX, ch);
}

void halt(int code) {
  // 规范写法：把程序的退出码 code 放进 a0 寄存器，然后 ebreak。
  // 这样你的 npc_trap(int a0_val) 就能精确识别是 GOOD TRAP 还是 BAD TRAP 了！
  asm volatile("mv a0, %0; ebreak" : : "r"(code));
  while (1);
}

void _trm_init() {
  char *src = &_data_load_start;
  char *dst = &_data_start;
  while (dst < &_data_end) {
    *dst++ = *src++;
  }

  for (char *p = &_bss_start; p < &_bss_end; p++) {
    *p = 0;
  }

  uart_init();
  int ret = main(mainargs);
  halt(ret);
}
