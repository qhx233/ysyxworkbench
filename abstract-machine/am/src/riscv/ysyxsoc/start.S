.section entry, "ax"
.globl _start
.type _start, @function

_start:
  # 将 sp 指针初始化到 8KB SRAM 的末尾 (0x0f000000 + 0x2000)
  li sp, 0x0f002000
  # 跳转到 C 语言环境的架构初始化函数
  jal _trm_init