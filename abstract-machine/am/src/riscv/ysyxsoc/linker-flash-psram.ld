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
  _ssbl_load_start = LOADADDR(.ssbl_text);
  _ssbl_start_addr = ADDR(.ssbl_text);
  .ssbl_text : {
    *(.ssbl_entry)
    *(.ssbl_text*)
  } > sram AT> flash
  _ssbl_load_end = LOADADDR(.ssbl_text) + SIZEOF(.ssbl_text);
  _ssbl_end_addr = .;

  . = ORIGIN(psram);
  _psram_load_start = LOADADDR(.psram_text);
  _psram_start_addr = ADDR(.psram_text);
  .psram_text : {
    *(.psram_entry)
    *(.text*)
  } > psram AT> flash

  .rodata : {
    *(.rodata*)
    *(.srodata*)
    . = ALIGN(4);
  } > psram AT> flash

  .data : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    _data_end = .;
  } > psram AT> flash
  _data_load_start = LOADADDR(.data);

  . = ALIGN(4);
  _psram_load_end = LOADADDR(.data) + SIZEOF(.data);
  _psram_end_addr = .;

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > psram

  . = ALIGN(4);
  _heap_start = .;
  _heap_end = ORIGIN(psram) + LENGTH(psram);
  _stack_bottom = ORIGIN(sram) + LENGTH(sram) - 0x1000;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
}
