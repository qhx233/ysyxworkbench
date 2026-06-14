ENTRY(_start)

MEMORY {
  flash (rx)   : ORIGIN = 0x30000000, LENGTH = 16M
  sram  (rwx)  : ORIGIN = 0x0f000000, LENGTH = 8K
  psram (rwx)  : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS {
  .flash_text : {
    *(entry)
    *(.flash_text*)
  } > flash AT> flash

  . = ORIGIN(sram);
  _sram_load_start = LOADADDR(.sram_text);
  _sram_start_addr = ADDR(.sram_text);
  .sram_text : {
    *(.sram_entry)
    *(.text*)
  } > sram AT> flash

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > sram AT> flash

  .data : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    _data_end = .;
  } > sram AT> flash
  _data_load_start = LOADADDR(.data);

  . = ALIGN(4);
  _sram_load_end = LOADADDR(.data) + SIZEOF(.data);
  _sram_end_addr = .;

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > sram

  . = ALIGN(4);
  _heap_start = ORIGIN(psram);
  _heap_end = ORIGIN(psram) + LENGTH(psram);
  _stack_bottom = ORIGIN(sram) + LENGTH(sram) - 0x1000;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
}
