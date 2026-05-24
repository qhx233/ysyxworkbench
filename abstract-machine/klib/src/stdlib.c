#include <am.h>
#include <klib.h>
#include <klib-macros.h>


#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)
static unsigned long int next = 1;

static char *hbrk = NULL;

int rand(void) {
  // RAND_MAX assumed to be 32767
  next = next * 1103515245 + 12345;
  return (unsigned int)(next/65536) % 32768;
}

void srand(unsigned int seed) {
  next = seed;
}

int abs(int x) {
  return (x < 0 ? -x : x);
}

int atoi(const char* nptr) {
  int x = 0;
  while (*nptr == ' ') { nptr ++; }
  while (*nptr >= '0' && *nptr <= '9') {
    x = x * 10 + *nptr - '0';
    nptr ++;
  }
  return x;
}

void *malloc(size_t size) {
  // On native, malloc() will be called during initializaion of C runtime.
  // Therefore do not call panic() here, else it will yield a dead recursion:
  //   panic() -> putchar() -> (glibc) -> malloc() -> panic()
#if !(defined(__ISA_NATIVE__) && defined(__NATIVE_USE_KLIB__))
  if (hbrk == NULL) {
    hbrk = (char *)heap.start;
  }

  // 2. 内存对齐：将 size 向上取整到 8 的倍数，防止地址非对齐异常
  size = (size + 7) & ~7;

  // 3. 记录当前可用地址的首地址
  char *old_hbrk = hbrk;

  // 4. 移动水位线
  hbrk += size;

  // 5. 溢出检查：如果超过了物理内存的尽头，直接宕机
  if (hbrk > (char *)heap.end) {
    panic("Heap out of memory!");
  }

  // 6. 返回分配好的内存地址
  return old_hbrk;


#endif
  return NULL;
}

void free(void *ptr) {
}

#endif
