ENTRY(_start)

SECTIONS {
  /* 1. MROM 空间：存放所有的代码和初始数据，基址 0x20000000 */
  . = 0x20000000;
  
  .text : {
    *(entry)     /* 确保 start.S 里的 _start 在最开头 */
    *(.text*)
  }
  
  .rodata : {
    *(.rodata*)
  }
  
  .data : {
    *(.data*)
  }
  
  .bss : {
    *(.bss*)
    *(.sbss*)
  }

  /* 2. SRAM 空间：给 C 语言运行时的栈和堆使用 (0x0f000000 ~ 0x0f001fff) */
  /* 栈向下生长，所以栈顶设在 8KB SRAM 的最高处 */
  _stack_top = 0x0f002000;  
  
  /* 剩下给堆区留点位置，以满足 TRM 的 API 要求 */
  _heap_start = 0x0f000000; 
  _heap_end = 0x0f001000;   /* 给栈预留 4KB 空间 */
}