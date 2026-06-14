ENTRY(_start)

MEMORY {
  flash (rx)   : ORIGIN = 0x30000000, LENGTH = 16M
  sram  (rwx)  : ORIGIN = 0x0f000000, LENGTH = 8K
  sdram (rwx)  : ORIGIN = 0xa0000000, LENGTH = 128M
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

  . = ORIGIN(sdram);
  _sdram_load_start = LOADADDR(.sdram_text);
  _sdram_start_addr = ADDR(.sdram_text);
  .sdram_text : {
    *(.sdram_entry)
    *(.text*)
  } > sdram AT> flash

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > sdram AT> flash

  .data : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    _data_end = .;
  } > sdram AT> flash
  _data_load_start = LOADADDR(.data);

  . = ALIGN(4);
  _sdram_load_end = LOADADDR(.data) + SIZEOF(.data);
  _sdram_end_addr = .;

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > sdram

  . = ALIGN(4);
  _heap_start = .;
  _heap_end = ORIGIN(sdram) + LENGTH(sdram);
  _stack_bottom = ORIGIN(sram) + LENGTH(sram) - 0x1000;
  _stack_top = ORIGIN(sram) + LENGTH(sram);
}
