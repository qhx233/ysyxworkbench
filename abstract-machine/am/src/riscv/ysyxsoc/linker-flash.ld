ENTRY(_start)

MEMORY {
  flash (rx)   : ORIGIN = 0x30000000, LENGTH = 16M
  sram  (rwx)  : ORIGIN = 0x0f000000, LENGTH = 8K
  psram (rwx)  : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS {
  .text : {
    *(entry)
    *(.text*)
  } > flash AT> flash

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > flash AT> flash

  .data : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    _data_end = .;
  } > psram AT> flash
  _data_load_start = LOADADDR(.data);

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > psram

  . = ALIGN(4);
  _heap_start = .;
  _stack_bottom = ORIGIN(sram) + LENGTH(sram) - 0x1000;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
  _heap_end = ORIGIN(psram) + LENGTH(psram);
}
