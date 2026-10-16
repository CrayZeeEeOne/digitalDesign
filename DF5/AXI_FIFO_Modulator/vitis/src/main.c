/*
 * main.c -- DF5 signal viewer: record one capture from the I/Q source, then
 * show it; keys switch screens, zoom and scroll (app/keys.h).
 *
 *   source/  where I/Q comes from          dsp/  demodulator chain, FFT
 *   app/     capture, screens, keys         gfx/  TFT driver, plot primitives
 *   hal/     drivers of the PL blocks       bsp/  startup, linker script, addresses
 */
#include <stdint.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "config.h"
#include "hal/spi_tft.h"
#include "hal/system_ctrl.h"
#include "gfx/tft.h"
#include "source/src_synth.h"
#include "app/viewer.h"
#include "app/keys.h"

static spi_tft_t spi;
static tft_t tft;
static system_ctrl_t sys;
static src_synth_t synth;
static viewer_t viewer;
static keys_t keys;
static int16_t iq[CFG_IQ_BLOCK * 2u];

/* Milliseconds since start, from the free-running AXI clock counter. */
static uint32_t millis(void)
{
    static uint32_t last_tick, ms, rem;
    uint32_t tick = system_ctrl_get_tick(&sys);

    rem += tick - last_tick;
    last_tick = tick;
    ms += rem / (CFG_ACLK_HZ / 1000u);
    rem %= (CFG_ACLK_HZ / 1000u);
    return ms;
}

int main(void)
{
    iq_source_t *src = &synth.base;
    uint32_t blocks = 0u;
    int redraw = 1;

    xil_printf("\r\n=== DF5 signal viewer ===\r\n");

    if (spi_tft_init(&spi, XPAR_TFT_TOP_0_BASEADDR, CFG_ACLK_HZ, CFG_TFT_SCLK_HZ) != 0) {
        xil_printf("ERROR: SPI TFT core not found\r\n");
        return -1;
    }

    tft_init(&tft, &spi, TFT_ROT_90);
    spi_tft_backlight(&spi, 1);
    system_ctrl_init(&sys, XPAR_SYSTEM_CTRL_TOP_0_BASEADDR);

    src_synth_init(&synth);
    viewer_init(&viewer);
    keys_init(&keys);
    (void)millis();

    while (1) {
        if (!viewer_done(&viewer)) {
            iq_source_read(src, iq, CFG_IQ_BLOCK);
            viewer_process_block(&viewer, iq, CFG_IQ_BLOCK);
            if (viewer_done(&viewer) || (++blocks % 64u) == 0u)
                redraw = 1;
        } else {
            key_action_t a = keys_poll(&keys, system_ctrl_get_buttons_raw(&sys), millis());
            if (a != KEY_NONE && viewer_key(&viewer, a))
                redraw = 1;
        }

        if (redraw) {
            viewer_draw(&viewer, &tft);
            spi_tft_flush(&spi);
            redraw = 0;
        }
    }

    return 0;
}
