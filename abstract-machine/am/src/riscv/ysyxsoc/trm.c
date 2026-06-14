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
#ifdef __YSYXSOC_LOAD_TO_SRAM__
extern char _sram_load_start;
extern char _sram_load_end;
extern char _sram_start_addr;
extern char _sram_end_addr;
void _sram_start(void);
#endif
#ifdef __YSYXSOC_LOAD_TO_PSRAM__
extern char _ssbl_load_start;
extern char _ssbl_load_end;
extern char _ssbl_start_addr;
extern char _ssbl_end_addr;
extern char _psram_load_start;
extern char _psram_load_end;
extern char _psram_start_addr;
extern char _psram_end_addr;
void _ssbl_start(void);
void _psram_start(void);
#endif
#ifdef __YSYXSOC_LOAD_TO_SDRAM__
extern char _ssbl_load_start;
extern char _ssbl_load_end;
extern char _ssbl_start_addr;
extern char _ssbl_end_addr;
extern char _sdram_load_start;
extern char _sdram_load_end;
extern char _sdram_start_addr;
extern char _sdram_end_addr;
void _ssbl_start(void);
void _sdram_start(void);
#endif

int main(const char *args);

Area heap = RANGE(&_heap_start, &_heap_end);

// 处理 mainargs 传参 (兼容 klib 宏)
#ifndef MAINARGS_PLACEHOLDER
#define MAINARGS_PLACEHOLDER ""
#endif
static const char mainargs[MAINARGS_MAX_LEN] = TOSTRING(MAINARGS_PLACEHOLDER);

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

#if !defined(__YSYXSOC_LOAD_TO_SRAM__) && !defined(__YSYXSOC_LOAD_TO_PSRAM__) && !defined(__YSYXSOC_LOAD_TO_SDRAM__)
static void copy_data() {
  char *src = &_data_load_start;
  char *dst = &_data_start;
  while (dst < &_data_end) {
    *dst++ = *src++;
  }
}
#endif

static void clear_bss() {
  for (char *p = &_bss_start; p < &_bss_end; p++) {
    *p = 0;
  }
}

__attribute__((section(".flash_text"), noinline))
static void fsbl_copy_image(char *dst, char *src, char *end) {
  while ((((uintptr_t)dst | (uintptr_t)src | (uintptr_t)end) & 3) == 0 && src + 4 <= end) {
    *(volatile uint32_t *)dst = *(volatile uint32_t *)src;
    dst += 4;
    src += 4;
  }
  while (src < end) {
    *dst++ = *src++;
  }
}

#if defined(__YSYXSOC_LOAD_TO_PSRAM__) || defined(__YSYXSOC_LOAD_TO_SDRAM__)
__attribute__((section(".ssbl_text"), noinline))
static void ssbl_copy_image(char *dst, char *src, char *end) {
  while ((((uintptr_t)dst | (uintptr_t)src | (uintptr_t)end) & 3) == 0 && src + 4 <= end) {
    *(volatile uint32_t *)dst = *(volatile uint32_t *)src;
    dst += 4;
    src += 4;
  }
  while (src < end) {
    *dst++ = *src++;
  }
}
#endif

static void call_main() {
  uart_init();
  int ret = main(mainargs);
  halt(ret);
}

#ifdef __YSYXSOC_LOAD_TO_SRAM__
__attribute__((section(".flash_text"), noinline))
void _trm_init() {
  fsbl_copy_image(&_sram_start_addr, &_sram_load_start, &_sram_load_end);
  _sram_start();
  halt(1);
}

void _sram_init() {
  clear_bss();
  call_main();
}
#elif defined(__YSYXSOC_LOAD_TO_PSRAM__)
__attribute__((section(".flash_text"), noinline))
void _trm_init() {
  fsbl_copy_image(&_ssbl_start_addr, &_ssbl_load_start, &_ssbl_load_end);
  _ssbl_start();
  halt(1);
}

__attribute__((section(".ssbl_text"), noinline))
void _ssbl_init() {
  ssbl_copy_image(&_psram_start_addr, &_psram_load_start, &_psram_load_end);
  _psram_start();
  halt(1);
}

void _psram_init() {
  clear_bss();
  call_main();
}
#elif defined(__YSYXSOC_LOAD_TO_SDRAM__)
__attribute__((section(".flash_text"), noinline))
void _trm_init() {
  fsbl_copy_image(&_ssbl_start_addr, &_ssbl_load_start, &_ssbl_load_end);
  _ssbl_start();
  halt(1);
}

__attribute__((section(".ssbl_text"), noinline))
void _ssbl_init() {
  ssbl_copy_image(&_sdram_start_addr, &_sdram_load_start, &_sdram_load_end);
  _sdram_start();
  halt(1);
}

void _sdram_init() {
  clear_bss();
  call_main();
}
#else
void _trm_init() {
  copy_data();
  clear_bss();
  call_main();
}
#endif
