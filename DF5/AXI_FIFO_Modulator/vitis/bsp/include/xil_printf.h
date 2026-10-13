/* xil_printf.h -- no UART in the design: xil_printf is a no-op (bsp/stubs.c). */
#ifndef XIL_PRINTF_H
#define XIL_PRINTF_H

int xil_printf(const char *fmt, ...);

#endif
