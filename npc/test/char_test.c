#define UART_BASE 0x10000000L
#define UART_TX   0x0

void _start() {
  // 必须使用 volatile，防止编译器把这两条只写不读的语句优化掉
  *(volatile char *)(UART_BASE + UART_TX) = 'A';
  //*(volatile char *)(UART_BASE + UART_TX) = '\n';
  while (1); // 陷入死循环，防止程序跑飞
}