/* stubs.c -- the design has no UART, so console output is dropped. */
int xil_printf(const char *fmt, ...)
{
    (void)fmt;
    return 0;
}
