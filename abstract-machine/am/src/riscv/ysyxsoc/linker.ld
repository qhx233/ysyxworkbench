ENTRY(_start)

MEMORY {
  mrom (rx)  : ORIGIN = 0x20000000, LENGTH = 4K
  sram (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS {
  .text : {
    *(entry)
    *(.text*)
  } > mrom AT> mrom

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > mrom AT> mrom

  .data : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    _data_end = .;
  } > sram AT> mrom
  _data_load_start = LOADADDR(.data);

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > sram

  . = ALIGN(4);
  _heap_start = .;
  _stack_bottom = ORIGIN(sram) + LENGTH(sram) - 0x1000;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
  _heap_end = _stack_bottom;
}
