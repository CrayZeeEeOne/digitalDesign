/* st7789_emu.h -- frame buffer of the emulated ST7789 (its full 320x320 RAM window). */
#ifndef ST7789_EMU_H
#define ST7789_EMU_H

#include <stdint.h>

#define EMU_RAM_ROWS 320

extern uint16_t emu_fb[EMU_RAM_ROWS][EMU_RAM_ROWS];

#endif
