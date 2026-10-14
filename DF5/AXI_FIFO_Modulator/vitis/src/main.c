/*
 * main.c -- DF5 graph viewer: take an I/Q block from the source, run it
 * through the viewer, handle the keys, redraw when needed.
 *
 *   source/  where I/Q comes from          dsp/  demodulator chain, FFT
 *   app/     capture + screens              gfx/  TFT driver, plot primitives
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

static spi_tft_t spi;
static tft_t tft;
static system_ctrl_t sys;
static src_synth_t synth;
static viewer_t viewer;
static int16_t iq[CFG_IQ_BLOCK * 2u];

/* Key presses since the last call: latched events plus raw edges (SYS_BTN*_MASK). */
static uint32_t read_keys(void)
{
    static uint32_t raw_prev = 0u;
    uint32_t events = system_ctrl_get_press_events(&sys);
    uint32_t raw = system_ctrl_get_buttons_raw(&sys);

    events |= (raw & ~raw_prev) & (SYS_BTN1_MASK | SYS_BTN2_MASK);
    raw_prev = raw;
    if (events) system_ctrl_clear_press_events(&sys, events);
    return events;
}

int main(void)
{
    iq_source_t *src = &synth.base;
    uint32_t blocks = 0u;
    uint32_t keys;
    int redraw = 1;

    xil_printf("\r\n=== DF5 LCD Graph Viewer ===\r\n");

    if (spi_tft_init(&spi, XPAR_TFT_TOP_0_BASEADDR, CFG_ACLK_HZ, CFG_TFT_SCLK_HZ) != 0) {
        xil_printf("ERROR: SPI TFT core not found\r\n");
        return -1;
    }

    tft_init(&tft, &spi, TFT_ROT_90);
    spi_tft_backlight(&spi, 1);
    system_ctrl_init(&sys, XPAR_SYSTEM_CTRL_TOP_0_BASEADDR);

    src_synth_init(&synth);
    viewer_init(&viewer);

    xil_printf("KEY1 -> next view, KEY2 -> previous view\r\n");

    /*
     * Record one capture, then the picture stays still and is redrawn only on a key press.
     * Spectrum screens keep taking new blocks until their plot is drawn (app/view_spectrum.h).
     */
    while (1) {
        if (viewer_busy(&viewer)) {
            int was_done = viewer_done(&viewer);

            iq_source_read(src, iq, CFG_IQ_BLOCK);
            viewer_process_block(&viewer, iq, CFG_IQ_BLOCK);
            if (!was_done && (viewer_done(&viewer) || (++blocks % 64u) == 0u))
                redraw = 1;
        }

        keys = read_keys();
        if (keys & SYS_BTN1_MASK) viewer_next(&viewer);
        if (keys & SYS_BTN2_MASK) viewer_prev(&viewer);
        if (keys) redraw = 1;

        if (redraw) {
            viewer_draw(&viewer, &tft);
            spi_tft_flush(&spi);
            redraw = 0;
        }
    }

    return 0;
}
