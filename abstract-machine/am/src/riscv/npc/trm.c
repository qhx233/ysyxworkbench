#include <am.h>
#include <klib-macros.h>
#include <klib.h>
#include <stdio.h>

#define SERIAL_PORT 0x10000000

static inline uint32_t get_mvendorid(){
  uint32_t vendorid;
  __asm__ __volatile__("csrr %0, mvendorid" : "=r"(vendorid));
  return vendorid;
}

static inline uint32_t get_marchid(){
  uint32_t archid;
  __asm__ __volatile__("csrr %0, marchid" : "=r"(archid));
  return archid;
}

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END  ((uintptr_t)&_pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
static const char mainargs[MAINARGS_MAX_LEN] = TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

void putch(char ch) {
  *(volatile uint8_t *)SERIAL_PORT = ch;
 
}

void halt(int code) {
  asm volatile("mv a0, %0; ebreak" : : "r"(code));
  while (1);
}

void _trm_init() {
  //uint32_t vendorid = get_mvendorid();
  //uint32_t archid   = get_marchid();

  // 2. 华丽地打印出来
  //printf("\n========================================\n");
  //printf("  Core Name : NPC\n");
  //printf("  Vendor ID : 0x%08x\n", vendorid); 
  //printf("  Arch ID   : %d\n", archid);
  //printf("========================================\n\n");
  int ret = main(mainargs);
  halt(ret);
}
