/*
 * crt0.c -- bare-metal entry point.
 *
 * The ELF is loaded over JTAG (scripts/run_board.tcl), so .data already holds
 * its initial values. The stack starts just below the top of the 32 KB LMB BRAM
 * and grows down towards .bss (see bsp/lscript.ld).
 */
extern int main(void);

void _start(void)
{
    __asm__ volatile ("addi r1, r0, 0x7FF0");
    (void)main();
    for (;;) { __asm__ volatile ("nop"); }
}
