/* lscript.ld -- everything in the 32 KB LMB BRAM at 0x0 (code, data, bss); stack on top (bsp/crt0.S). */
ENTRY(_start)
MEMORY
{
  bram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00008000
}
SECTIONS
{
  .text : {
    *(.vectors)
    *(.text*)
    *(.rodata*)
    *(.gnu.linkonce.t*)
    *(.gnu.linkonce.r*)
  } > bram
  .data : {
    *(.data*)
    *(.gnu.linkonce.d*)
  } > bram
  .bss (NOLOAD) : {
    *(.sbss*)
    *(.bss*)
    *(COMMON)
  } > bram
  . = ALIGN(8);
  _end = .;
}

/* crt0.S puts the stack top at 0x7FF0; keep at least 1 KB for it. */
ASSERT(_end <= 0x7BF0, "BRAM full: less than 1 KB left for the stack")
