/*
 * xparameters.h -- base addresses of the "microblaze" Block Design.
 *
 * Hand-written replacement for the Vitis-generated header: the firmware is
 * built bare-metal with mb-gcc (scripts/build_elf.bat), without a Vitis
 * platform. Must match assign_bd_address in scripts/create_bd.tcl.
 */
#ifndef XPARAMETERS_H
#define XPARAMETERS_H

#define XPAR_TFT_TOP_0_BASEADDR          0x00010000u
#define XPAR_SYSTEM_CTRL_TOP_0_BASEADDR  0x44A10000u

#endif
