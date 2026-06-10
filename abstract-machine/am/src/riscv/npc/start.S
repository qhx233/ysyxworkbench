.section entry, "ax"
.globl _start
.type _start, @function

_start:
  /* 规范：清空帧指针，标志着调用栈的起点 */
  mv s0, zero
  
  /* 规范：从链接脚本中动态获取栈顶物理地址，赋值给栈指针 sp */
  la sp, _stack_top
  
  /* 跳转到 C 语言环境的初始化函数 */
  call _trm_init

.size _start, . - _start