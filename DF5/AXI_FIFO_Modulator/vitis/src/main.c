/*
 * main.c -- DF5 signal viewer. The DSP runs in the PL (dsp_top); the firmware
 * configures it and draws. Three states (app/viewer.h):
 *
 *   LIVE    default: the RTL generator runs in real time (4.5 MS/s); the PL
 *           computes the spectrum of every block into a ring of waterfall rows
 *           and records ~73 ms windows for RAW / BITS, re-armed right after
 *           each read-out. The current screen is redrawn every CFG_LIVE_FRAME_MS
 *           (RAW / BITS when a new window is there). K2: pause.
 *   PAUSE   the last picture frozen, zoom and scroll work. K1+K2: live again.
 *   STATIC  replay of SIM.IQ from the SD card (K2 on the SD CARD screen, or after
 *           a file upload from the PC): one capture, not real time -- the card
 *           reads ~450 KB/s, real time needs 18 MB/s. K1+K2: live again.
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
#include "hal/iq_stream.h"
#include "gfx/tft.h"
#include "app/viewer.h"
#include "app/keys.h"
#include "app/sd_test.h"
#include "app/sd_format.h"
#include "app/view_sd.h"
#include "app/sd_iq.h"

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

enum { ST_LIVE, ST_PAUSE, ST_REPLAY, ST_STATIC };
static int state;

/* Holding K2 this long on the SD CARD screen formats the card (keys repeat every 120 ms). */
#define FORMAT_HOLD_REPEATS 22u

/* Live waterfall: rows of the PL ring, the newest at the top. */
#define LIVE_ROW_MS10   ((uint32_t)(((1u << CFG_LIVE_WF_SHIFT) * SPEC_FFT_N * 10000u) / (CFG_SAMPLE_RATE_HZ / 1000u) / 1000u))
#define LIVE_ROWS_MAX   192u   /* about the height of the plot: one row per line */

typedef struct {
    uint32_t newest;           /* absolute index of the top row */
    uint8_t buf[SPEC_BINS];
} live_wf_t;

static live_wf_t live_wf;
static uint8_t live_fft[SPEC_BINS];
static uint32_t live_fft_from;  /* first ring row not yet in a drawn FFT */

/* Frames drawn and the time spent drawing them: read over JTAG to see the frame rate. */
volatile uint32_t stat_frames, stat_draw_ms;

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

/* Called between the windows of a long redraw: decoded packets are not lost. */
static void poll_dsp(void)
{
    (void)dsp_rtl_poll(&dsp);
}

/* microSD test; LED1 = card read OK, LED2 = error. */
static void run_sd_test(void)
{
    sd_test_run(&sd_info, &sd, &sd_spi, ticks, CFG_ACLK_HZ);
    system_ctrl_set_leds(&sys, (sd_info.err == SD_OK && sd_info.fat_bits) ? 1u : 2u);
    sd_mounted = (sd_info.err == SD_OK && sd_info.fat_bits) && sd_iq_mount(&sd, &sd_spi) == 0;
}

static const uint8_t *live_row(void *ctx, uint16_t i)
{
    live_wf_t *w = (live_wf_t *)ctx;

    dsp_rtl_read_row(&dsp, w->newest - i, w->buf);
    return w->buf;
}

/* Live spectra of this frame: the waterfall ends at the newest row; the FFT trace
   is the max over the rows since the last frame (no packet slips between frames). */
static void live_spectra(void)
{
    uint32_t rows = dsp_rtl_spec_rows(&dsp);
    uint32_t r, b;
    uint8_t row[SPEC_BINS];

    if (rows == 0u) return;
    live_wf.newest = rows - 1u;
    viewer.wf.nrows = (uint16_t)((rows < LIVE_ROWS_MAX) ? rows : LIVE_ROWS_MAX);
    viewer.wf.span_ms10 = viewer.wf.nrows * LIVE_ROW_MS10;

    if (live_fft_from + 255u < rows) live_fft_from = rows - 1u;   /* fell behind the ring */
    if (live_fft_from >= rows) live_fft_from = rows - 1u;
    for (b = 0u; b < SPEC_BINS; b++) live_fft[b] = 0u;
    for (r = live_fft_from; r < rows; r++) {
        dsp_rtl_read_row(&dsp, r, row);
        for (b = 0u; b < SPEC_BINS; b++) if (row[b] > live_fft[b]) live_fft[b] = row[b];
    }
    live_fft_from = rows;
}

static void go_live(void)
{
    sd_iq_close();
    dsp_rtl_live_start(&dsp);
    state = ST_LIVE;
    viewer.state = VSTATE_LIVE;
    viewer.cap = 0;                    /* until the first window is there */
    viewer.fft = live_fft;
    viewer.fft_tag = "LIVE";
    viewer.wf.row = live_row;
    viewer.wf.ctx = &live_wf;
    viewer.wf.nrows = 0u;
    viewer.wf.live = 1u;
    viewer.source = "RTL GENERATOR";
    live_fft_from = dsp_rtl_spec_rows(&dsp);
}

static void go_pause(void)
{
    dsp_rtl_live_spectrum(&dsp, 0);    /* the ring keeps its rows */
    state = ST_PAUSE;
    viewer.state = VSTATE_PAUSE;
    viewer.fft_tag = "PAUSE";
}

static void resume_live(void)
{
    dsp_rtl_live_spectrum(&dsp, 1);
    dsp_rtl_rearm(&dsp);
    state = ST_LIVE;
    viewer.state = VSTATE_LIVE;
    viewer.fft_tag = "LIVE";
    live_fft_from = dsp_rtl_spec_rows(&dsp);
}

/* One capture from SD_IQ_FILE (file recorded from its first sample: no trigger wait). */
static int start_replay(void)
{
    uint32_t n;

    if (!sd_mounted || sd_iq_open(SD_IQ_FILE, &n) != 0) return 0;
    iq_stream_flush(&iqs);
    dsp_rtl_set_source(&dsp, DSP_SRC_STREAM);
    dsp_rtl_start(&dsp, 1);
    viewer_use_capture(&viewer, 0);
    viewer.source = "SD: " SD_IQ_FILE;
    state = ST_REPLAY;
    return 1;
}

int main(void)
{
    int redraw = 1, full = 1, new_cap = 0;
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
    viewer.sd = &sd_info;
    viewer.sd_fmt = &sd_fmt;
    keys_init(&keys);
    tft.idle = poll_dsp;
    go_live();
    (void)millis();

    while (1) {
        static uint32_t hold_n, hold_last;
        uint32_t now = millis();
        key_action_t a = keys_poll(&keys, system_ctrl_get_buttons_raw(&sys), now);

        /*------------------------------------------------------ keys */
        if (a == KEY_BOTH && state != ST_LIVE) {
            if (state == ST_PAUSE) resume_live(); else go_live();
            full = redraw = 1;
        } else if (viewer.mode == VIEW_SD && a == KEY_ZOOM) {
            /* K2 on the SD CARD screen: test the card again, replay SIM.IQ if it is there */
            run_sd_test();
            if (start_replay()) viewer.mode = VIEW_RAW;
            full = redraw = 1;
        } else if (viewer.mode == VIEW_SD && a == KEY_PAN_FWD) {
            /* K2 held: count repeats of one continuous hold, format after ~3 s */
            hold_n = (now - hold_last > 300u) ? 1u : hold_n + 1u;
            hold_last = now;
            if (hold_n == FORMAT_HOLD_REPEATS) {
                sd_iq_close();
                view_sd_formatting(&tft);
                spi_tft_flush(&spi);
                system_ctrl_set_leds(&sys, 3u);
                sd_format_run(&sd_fmt, &sd, &sd_spi, ticks, CFG_ACLK_HZ);
                run_sd_test();          /* show the new file system */
                go_live();
                full = redraw = 1;
            }
        } else if (state == ST_LIVE && a == KEY_ZOOM && viewer.mode != VIEW_SD) {
            go_pause();
            full = redraw = 1;
        } else if (a != KEY_NONE && viewer_key(&viewer, a)) {
            full = redraw = 1;
        }

        /* a file sent from the PC (tools/sd_upload.py): replay it */
        if (sd_mounted && sd_iq_upload_poll() && start_replay()) full = redraw = 1;

        /*---------------------------------------------------- the PL */
        if (state == ST_LIVE || state == ST_REPLAY) {
            int st;

            if (state == ST_REPLAY) sd_iq_feed(&iqs);
            st = dsp_rtl_poll(&dsp);
            if (st == DSP_CAP_DONE) {
                if (state == ST_LIVE) {
                    dsp_rtl_read_capture(&dsp, &cap, 0);
                    dsp_rtl_rearm(&dsp);          /* the next window records while we draw */
                    if (!viewer.cap) full = 1;
                    viewer.cap = &cap;
                    new_cap = 1;
                } else {
                    sd_iq_close();
                    dsp_rtl_read_capture(&dsp, &cap, 1);
                    viewer_use_capture(&viewer, &cap);
                    state = ST_STATIC;
                    full = redraw = 1;
                }
            } else if (state == ST_REPLAY && now - last_draw >= 100u) {
                viewer_set_progress(&viewer, dsp_rtl_capture_pos(&dsp), CFG_CAPTURE_SAMPLES);
                full = redraw = 1;
            }
        }

        /*---------------------------------------------------- the screen */
        if (state == ST_LIVE && now - last_draw >= CFG_LIVE_FRAME_MS) {
            if (viewer.mode == VIEW_FFT || viewer.mode == VIEW_WATERFALL) {
                live_spectra();
                redraw = 1;
            } else if (new_cap) {
                redraw = 1;
            }
        }
        if (redraw) {
            if (viewer.mode == VIEW_FFT || viewer.mode == VIEW_WATERFALL)
                if (state == ST_LIVE && viewer.wf.nrows == 0u) live_spectra();
            viewer_draw(&viewer, &tft, full);
            spi_tft_flush(&spi);
            stat_frames++;
            stat_draw_ms += millis() - now;
            last_draw = now;
            redraw = full = new_cap = 0;
        }
    }

    return 0;
}
