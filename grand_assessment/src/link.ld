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
  . = ALIGN(0x1000);
  .h_pt : { *(.root_pt) }
  . = ALIGN(0x1000);
  .g_pt : { *(.leaf_pt) }
  . = ALIGN(0x1000);
  .test : { *(.test) }
}
