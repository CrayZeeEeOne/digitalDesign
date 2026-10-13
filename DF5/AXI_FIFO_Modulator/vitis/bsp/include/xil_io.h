/* xil_io.h -- minimal MMIO accessors (subset of the Xilinx standalone BSP). */
#ifndef XIL_IO_H
#define XIL_IO_H

#include <stdint.h>

static inline uint32_t Xil_In32(uint32_t addr) { return *(volatile uint32_t *)addr; }
static inline void Xil_Out32(uint32_t addr, uint32_t val) { *(volatile uint32_t *)addr = val; }

#endif
