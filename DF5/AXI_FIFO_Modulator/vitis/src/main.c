/*
 * main.c -- DF5 signal viewer: the DSP runs in the PL (dsp_top: test generator
 * -> demodulator -> capture, FFT, waterfall); the firmware configures it, waits
 * for one capture, reads it out and shows it; keys switch screens, zoom and
 * scroll (app/keys.h).
 *
 *   app/     capture data, screens, keys    gfx/  TFT driver, plot primitives
 *   hal/     drivers of the PL blocks       bsp/  startup, linker script, addresses
 *   the same DSP in C, for the host simulator only: tools/host_sim/model
 */
#include <stdint.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "config.h"
#include "hal/spi_tft.h"
#include "hal/system_ctrl.h"
#include "hal/axi_qspi.h"
#include "hal/sd_card.h"
#include "hal/dsp_rtl.h"
#include "gfx/tft.h"
#include "app/viewer.h"
#include "app/keys.h"
#include "app/sd_test.h"
#include "app/sd_format.h"
#include "app/view_sd.h"
#include "app/sd_iq.h"
#include "hal/iq_stream.h"

static spi_tft_t spi;
static tft_t tft;
static system_ctrl_t sys;
static dsp_rtl_t dsp;
static cap_data_t cap;
static viewer_t viewer;
static keys_t keys;
static axi_qspi_t sd_spi;
static sd_card_t sd;
static sd_info_t sd_info;
static sd_format_result_t sd_fmt;
static iq_stream_t iqs;
static int sd_mounted;         /* the card's FAT is mounted (replay / upload possible) */
static int replay;             /* the current capture replays SD_IQ_FILE */

/* Holding K2 this long on the SD CARD screen formats the card (keys repeat every 120 ms). */
#define FORMAT_HOLD_REPEATS 22u

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
    sd_mounted = (sd_info.err == SD_OK && sd_info.fat_bits) && sd_iq_mount(&sd, &sd_spi) == 0;
}

/*
 * New capture: replay of SD_IQ_FILE when the card has it (the file is recorded
 * from its first sample, so no waiting for a packet end), else the test generator.
 */
static void start_capture(void)
{
    uint32_t n;

    viewer_set_capture(&viewer, 0);
    replay = sd_mounted && sd_iq_open(SD_IQ_FILE, &n) == 0;
    iq_stream_flush(&iqs);
    dsp_rtl_set_source(&dsp, replay ? DSP_SRC_STREAM : DSP_SRC_GEN);
    dsp_rtl_start(&dsp, replay, &cap);
    viewer.source = replay ? "SD: " SD_IQ_FILE : "RTL GENERATOR";
}

int main(void)
{
    int redraw = 1, capturing = 1;
    uint32_t last_draw = 0u;

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

    viewer_init(&viewer);
    if (dsp_rtl_init(&dsp, XPAR_DSP_TOP_0_BASEADDR) != 0) {
        tft_clear(&tft, TFT_BLACK);
        tft_draw_text(&tft, 10, 100, "DSP CORE NOT FOUND", TFT_RED, TFT_BLACK, 2);
        spi_tft_flush(&spi);
        return -1;
    }
    if (iq_stream_init(&iqs, XPAR_IQ_STREAM_TOP_0_BASEADDR) != 0) {
        tft_clear(&tft, TFT_BLACK);
        tft_draw_text(&tft, 10, 100, "IQ STREAM NOT FOUND", TFT_RED, TFT_BLACK, 2);
        spi_tft_flush(&spi);
        return -1;
    }
    start_capture();
    viewer.sd = &sd_info;
    viewer.sd_fmt = &sd_fmt;
    keys_init(&keys);
    (void)millis();

    while (1) {
        /* a file sent from the PC (scripts/sd_upload.tcl): capture again from it */
        if (sd_mounted && sd_iq_upload_poll()) {
            start_capture();
            capturing = 1;
        }

        if (capturing) {
            /* the PL records in real time (~0.1 s); the progress bar every 20 ms */
            uint32_t now = millis();

            if (replay) sd_iq_feed(&iqs);
            if (dsp_rtl_poll(&dsp, &cap) == DSP_CAP_DONE) {
                if (replay) sd_iq_close();
                dsp_rtl_read_capture(&dsp, &cap);
                viewer_set_capture(&viewer, &cap);
                capturing = 0;
                redraw = 1;
            } else if (now - last_draw >= 20u) {
                viewer_set_progress(&viewer, dsp_rtl_capture_pos(&dsp), CFG_CAPTURE_SAMPLES);
                last_draw = now;
                redraw = 1;
            }
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
                    start_capture();
                    capturing = 1;
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
