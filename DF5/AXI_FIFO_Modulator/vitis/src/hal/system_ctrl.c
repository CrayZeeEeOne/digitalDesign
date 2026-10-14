#include "hal/system_ctrl.h"
#include "xil_io.h"

void system_ctrl_init(system_ctrl_t *sys, uint32_t base)
{
    sys->base = base;
}

uint32_t system_ctrl_read(const system_ctrl_t *sys, uint32_t reg)
{
    return Xil_In32(sys->base + reg);
}

void system_ctrl_write(const system_ctrl_t *sys, uint32_t reg, uint32_t value)
{
    Xil_Out32(sys->base + reg, value);
}

uint32_t system_ctrl_get_press_events(const system_ctrl_t *sys)
{
    return system_ctrl_read(sys, SYS_REG_BTN_EVENT) & (SYS_BTN1_MASK | SYS_BTN2_MASK);
}

uint32_t system_ctrl_get_buttons_raw(const system_ctrl_t *sys)
{
    return system_ctrl_read(sys, SYS_REG_BTN_RAW) & (SYS_BTN1_MASK | SYS_BTN2_MASK);
}

void system_ctrl_clear_press_events(const system_ctrl_t *sys, uint32_t mask)
{
    system_ctrl_write(sys, SYS_REG_BTN_EVENT, mask & (SYS_BTN1_MASK | SYS_BTN2_MASK));
}