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
#include "hal/axi_qspi.h"
#include "hal/sd_card.h"
#include "gfx/tft.h"
#include "source/src_synth.h"
#include "app/viewer.h"
#include "app/keys.h"
#include "app/sd_test.h"
#include "app/sd_format.h"
#include "app/view_sd.h"

static spi_tft_t spi;
static tft_t tft;
static system_ctrl_t sys;
static src_synth_t synth;
static viewer_t viewer;
static keys_t keys;
static axi_qspi_t sd_spi;
static sd_card_t sd;
static sd_info_t sd_info;
static sd_format_result_t sd_fmt;

/* Holding K2 this long on the SD CARD screen formats the card (keys repeat every 120 ms). */
#define FORMAT_HOLD_REPEATS 22u
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

static uint32_t ticks(void)
{
    return system_ctrl_get_tick(&sys);
}

/* microSD test; LED1 = card read OK, LED2 = error. */
static void run_sd_test(void)
{
    sd_test_run(&sd_info, &sd, &sd_spi, ticks, CFG_ACLK_HZ);
    system_ctrl_set_leds(&sys, (sd_info.err == SD_OK && sd_info.fat_bits) ? 1u : 2u);
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
    axi_qspi_init(&sd_spi, XPAR_AXI_QUAD_SPI_0_BASEADDR);
    run_sd_test();

    src_synth_init(&synth);
    viewer_init(&viewer);
    viewer.sd = &sd_info;
    viewer.sd_fmt = &sd_fmt;
    keys_init(&keys);
    (void)millis();

    while (1) {
        if (!viewer_done(&viewer)) {
            iq_source_read(src, iq, CFG_IQ_BLOCK);
            viewer_process_block(&viewer, iq, CFG_IQ_BLOCK);
            if (viewer_done(&viewer) || (++blocks % 64u) == 0u)
                redraw = 1;
        } else {
            static uint32_t hold_n, hold_last;
            uint32_t now = millis();
            key_action_t a = keys_poll(&keys, system_ctrl_get_buttons_raw(&sys), now);

            if (viewer.mode == VIEW_SD && a == KEY_ZOOM) {
                run_sd_test();          /* K2 short on the SD CARD screen: test the card again */
                redraw = 1;
            } else if (viewer.mode == VIEW_SD && a == KEY_PAN_FWD) {
                /* K2 held: count repeats of one continuous hold, format after ~3 s */
                hold_n = (now - hold_last > 300u) ? 1u : hold_n + 1u;
                hold_last = now;
                if (hold_n == FORMAT_HOLD_REPEATS) {
                    view_sd_formatting(&tft);
                    spi_tft_flush(&spi);
                    system_ctrl_set_leds(&sys, 3u);
                    sd_format_run(&sd_fmt, &sd, &sd_spi, ticks, CFG_ACLK_HZ);
                    run_sd_test();      /* show the new file system */
                    redraw = 1;
                }
            } else if (a != KEY_NONE && viewer_key(&viewer, a)) {
                redraw = 1;
            }
        }

        if (redraw) {
            viewer_draw(&viewer, &tft);
            spi_tft_flush(&spi);
            redraw = 0;
        }
    }

    return 0;
}
