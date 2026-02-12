OUTPUT_ARCH( "riscv" )
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
  .tor_section : {
    . = ALIGN(0x1000);
    _tor_start = .;
    *(.tor_section)
    . = ALIGN(0x1000);
    _tor_end = .;
  }
  .napot_section : { 
   . = ALIGN(0x1000);
    *(.napot_section) }

  . = ALIGN(16);
  .stack : ALIGN(0x1000){    
    _estack = .;
    . = . + 0x4000;   
    _sstack = .;
  }
}
