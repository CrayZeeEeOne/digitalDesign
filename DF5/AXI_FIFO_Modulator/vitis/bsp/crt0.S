/*
 * crt0.S -- bare-metal entry point, placed at address 0 (.vectors, see lscript.ld).
 *
 * Written in assembly so that no compiler prologue touches the stack before r1
 * is set (with -flto main may be inlined anywhere). The ELF is loaded over
 * JTAG (scripts/run_board.tcl), so .data already holds its initial values.
 * The stack starts just below the top of the 32 KB LMB BRAM and grows down
 * towards .bss.
 */
    .section .vectors, "ax"
    .globl  _start
_start:
    addik   r1, r0, 0x7FF0      /* stack top */
    brlid   r15, main
    nop                         /* delay slot */
    bri     0                   /* main returned: stay here */
