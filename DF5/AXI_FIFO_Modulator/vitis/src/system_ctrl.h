#ifndef SYSTEM_CTRL_H
#define SYSTEM_CTRL_H

#include <stdint.h>

typedef struct {
    uint32_t base;
} system_ctrl_t;

enum {
    SYS_REG_ID         = 0x00,
    SYS_REG_LED        = 0x04,
    SYS_REG_BTN_RAW    = 0x08,
    SYS_REG_BTN_EVENT  = 0x0C,
    SYS_REG_SPI_CLKDIV = 0x10,
    SYS_REG_SD_CS      = 0x14,
    SYS_REG_TICK       = 0x18,
    SYS_REG_SCRATCH    = 0x1C,
    SYS_REG_ACLK_HZ    = 0x20,
    SYS_REG_BTN_RAW_N  = 0x24
};

#define SYS_BTN1_MASK (1u << 0)
#define SYS_BTN2_MASK (1u << 1)

void system_ctrl_init(system_ctrl_t *sys, uint32_t base);
uint32_t system_ctrl_read(const system_ctrl_t *sys, uint32_t reg);
void system_ctrl_write(const system_ctrl_t *sys, uint32_t reg, uint32_t value);

uint32_t system_ctrl_get_press_events(const system_ctrl_t *sys);
void system_ctrl_clear_press_events(const system_ctrl_t *sys, uint32_t mask);

#endif
