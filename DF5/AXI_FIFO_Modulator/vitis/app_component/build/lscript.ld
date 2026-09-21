
OUTPUT_ARCH(microblaze)
ENTRY(_start)

MEMORY
{
    ram : ORIGIN = 0x00002000, LENGTH = 0x2000
}

SECTIONS
{
    .vectors.reset 0x00002000 :
    {
        KEEP(*(.vectors.reset))
    } > ram

    .vectors.sw_exception :
    {
        KEEP(*(.vectors.sw_exception))
    } > ram

    .vectors.interrupt :
    {
        KEEP(*(.vectors.interrupt))
    } > ram

    .vectors.hw_exception :
    {
        KEEP(*(.vectors.hw_exception))
    } > ram

    .text :
    {
        . = ALIGN(4);

        *(.text)
        *(.text.*)

        . = ALIGN(4);
    } > ram

    .init :
    {
        . = ALIGN(4);
        KEEP(*(.init))
        . = ALIGN(4);
    } > ram

    .fini :
    {
        . = ALIGN(4);
        KEEP(*(.fini))
        . = ALIGN(4);
    } > ram

    .rodata :
    {
        . = ALIGN(4);

        *(.rodata)
        *(.rodata.*)

        . = ALIGN(4);
    } > ram

    .sdata :
    {
        . = ALIGN(4);

        _SDA_BASE_ = . + 0x800;

        *(.sdata)
        *(.sdata.*)

        . = ALIGN(4);
    } > ram

    .sbss :
    {
        . = ALIGN(4);

        __sbss_start = .;

        *(.sbss)
        *(.sbss.*)

        __sbss_end = .;

        . = ALIGN(4);
    } > ram

    .data :
    {
        . = ALIGN(4);

        __data_start = .;

        *(.data)
        *(.data.*)

        __data_end = .;

        . = ALIGN(4);
    } > ram

    .sdata2 :
    {
        . = ALIGN(4);

        _SDA2_BASE_ = . + 0x800;

        *(.sdata2)
        *(.sdata2.*)

        . = ALIGN(4);
    } > ram

    .bss :
    {
        . = ALIGN(4);

        __bss_start = .;

        *(.bss)
        *(.bss.*)
        *(COMMON)

        __bss_end = .;

        . = ALIGN(4);
    } > ram

    .heap :
    {
        . = ALIGN(8);

        __heap_start = .;

        . += 0x400;

        __heap_end = .;

        . = ALIGN(8);
    } > ram

    .stack :
    {
        . = ALIGN(8);

        __stack_start = .;

        . += 0x800;

        __stack_end = .;

        . = ALIGN(8);
    } > ram

    PROVIDE(_heap_start  = __heap_start);
    PROVIDE(_heap_end    = __heap_end);

    PROVIDE(_stack       = __stack_end);
    PROVIDE(_stack_start = __stack_start);
    PROVIDE(_stack_end   = __stack_end);
}

