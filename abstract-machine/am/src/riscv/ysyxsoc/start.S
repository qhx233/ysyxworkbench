.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  la sp, _stack_top
  jal _trm_init

#if defined(__YSYXSOC_LOAD_TO_SRAM__)
.section .sram_entry, "ax"
.globl _sram_start
.type _sram_start, @function

_sram_start:
  mv s0, zero
  la sp, _stack_top
  jal _sram_init
#elif defined(__YSYXSOC_LOAD_TO_PSRAM__)
.section .ssbl_entry, "ax"
.globl _ssbl_start
.type _ssbl_start, @function

_ssbl_start:
  mv s0, zero
  la sp, _stack_top
  jal _ssbl_init

.section .psram_entry, "ax"
.globl _psram_start
.type _psram_start, @function

_psram_start:
  mv s0, zero
  la sp, _stack_top
  jal _psram_init
#elif defined(__YSYXSOC_LOAD_TO_SDRAM__)
.section .ssbl_entry, "ax"
.globl _ssbl_start
.type _ssbl_start, @function

_ssbl_start:
  mv s0, zero
  la sp, _stack_top
  jal _ssbl_init

.section .sdram_entry, "ax"
.globl _sdram_start
.type _sdram_start, @function

_sdram_start:
  mv s0, zero
  la sp, _stack_top
  jal _sdram_init
#endif
