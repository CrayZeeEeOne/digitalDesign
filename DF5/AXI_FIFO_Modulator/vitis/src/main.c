/*
 * main.c -- DF5 signal viewer. The DSP runs in the PL (dsp_top); the firmware
 * feeds it the capture file from the SD card, collects the results and draws.
 * States (app/viewer.h):
 *
 *   PLAY    default: CFG_PLAY_FILE (the real capture, 16.7 s at 4.5 MS/s) goes
 *           from the card straight into the DSP (sd_host on the 4-bit SD bus,
 *           exactly 4.5 MS/s: real time), once. The PL finds each
 *           hopping packet, demodulates it and records 21.8 ms around it for RAW /
 *           BITS (re-armed after each read-out); FFT shows the spectrum of the
 *           last rows, WATERFALL the whole file at once (0..16.7 s top to bottom,
 *           a white line at the playback position), FFT+WF both.
 *           The int8 file needs 9 MB/s, the bus gives 12.5; an int16 file
 *           (CFG_PLAY_FILE16) plays at ~0.7x.
 *           K2: pause.
 *   PAUSE   no samples go out: the PL waits, the picture is frozen, zoom and
 *           scroll work. K1+K2: play on.
 *   END     the file is over: nothing runs, the screens keep the last picture
 *           (the waterfall of the whole file), zoom and scroll work.
 *           K1+K2: the file from the start (a new waterfall).
 *   NOFILE  no card / no file: the SD CARD screen says so; K2 there tests again.
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
#include "hal/sd_host.h"
#include "hal/sd_card.h"
#include "hal/dsp_rtl.h"
#include "gfx/tft.h"
#include "gfx/plot.h"
#include "app/viewer.h"
#include "app/keys.h"
#include "app/frame.h"
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
static sd_host_t sd_host;
static sd_card_t sd;
static sd_info_t sd_info;
static sd_format_result_t sd_fmt;
static const char *play_name;    /* the file being played */
static int sd_mounted;         /* the card's FAT is mounted (replay / upload possible) */

enum { ST_PLAY, ST_PAUSE, ST_END, ST_NOFILE };
static int state;

/* Holding K2 this long on the SD CARD screen formats the card (keys repeat every 120 ms). */
#define FORMAT_HOLD_REPEATS 22u

/* Waterfall of the whole file: row i = the i-th 2^CFG_LIVE_WF_SHIFT blocks since the
   file started (116.5 ms each, 144 rows for 16.7 s), from the 256-row ring of the
   PL. The rows not played yet are empty; at the end of the file the ring is
   frozen and the picture stays. */
typedef struct {
    uint32_t rows;             /* SPEC_ROWS when this frame was prepared */
    uint32_t start;            /* ring row where this pass of the file started */
    uint8_t frozen;            /* the file is over: the ring is frozen */
    uint16_t nrows;            /* rows of the whole file */
    uint8_t buf[SPEC_BINS];
} file_wf_t;

static file_wf_t live_wf;
static uint8_t live_fft[SPEC_BINS];
static uint32_t live_fft_from;  /* first ring row not yet in a drawn FFT */

static rx_stats_t stats;
static uint32_t stats_seen;     /* dsp.nlog already counted */
static int prev_alarm_ch = -1;  /* channel of the previous alarm frame */

/* Frames drawn, the time spent drawing them, the card read rate: read over JTAG. */
volatile uint32_t stat_frames, stat_draw_ms, stat_play_ksps;

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
    sd_iq_close();                     /* the card test needs the bus */
    sd_test_run(&sd_info, &sd, &sd_host, ticks, CFG_ACLK_HZ);
    system_ctrl_set_leds(&sys, (sd_info.err == SD_OK && sd_info.fat_bits) ? 1u : 2u);
    sd_mounted = (sd_info.err == SD_OK && sd_info.fat_bits) && sd_iq_mount(&sd, &sd_host) == 0;
}

static const uint8_t *live_row(void *ctx, uint16_t i)
{
    file_wf_t *w = (file_wf_t *)ctx;
    uint32_t b;

    if (w->frozen || w->start + i < w->rows)
        dsp_rtl_read_row(&dsp, w->start + i, w->buf);
    else
        for (b = 0u; b < SPEC_BINS; b++) w->buf[b] = 0u;                /* not played yet */
    return w->buf;
}

/* The file starts: its rows begin at the current ring row. */
static void file_wf_restart(void)
{
    live_wf.frozen = 0u;
    viewer.wf.frozen = 0u;
    dsp_rtl_freeze(&dsp, 0);
    live_wf.start = dsp_rtl_spec_rows(&dsp);
    live_wf.nrows = (uint16_t)((sd_iq_len() / SPEC_FFT_N + (1u << CFG_LIVE_WF_SHIFT) - 1u) >> CFG_LIVE_WF_SHIFT);
    if (live_wf.nrows > 255u) live_wf.nrows = 255u;
}

/* Spectra of this frame: the waterfall of the whole file with the playback
   position; the FFT trace is the max over the rows since the last frame. */
static void live_spectra(void)
{
    uint32_t rows = dsp_rtl_spec_rows(&dsp);
    uint32_t r, b;
    uint8_t row[SPEC_BINS];

    live_wf.rows = rows;
    viewer.wf.nrows = live_wf.nrows;
    viewer.wf.span_ms10 = sd_iq_len() / (CFG_SAMPLE_RATE_HZ / 10000u);
    viewer.wf.cursor = (!live_wf.frozen && rows - live_wf.start < live_wf.nrows)
                     ? (uint16_t)(rows - live_wf.start) : 0xFFFFu;
    if (rows == 0u) return;
    if (live_wf.frozen) {                       /* the ring stands: the newest row */
        if (live_fft_from != rows) dsp_rtl_read_last(&dsp, live_fft);
        live_fft_from = rows;
        return;
    }

    if (live_fft_from + 255u < rows) live_fft_from = rows - 1u;   /* fell behind the ring */
    if (live_fft_from >= rows) return;                            /* nothing new: keep the trace */
    for (b = 0u; b < SPEC_BINS; b++) live_fft[b] = 0u;
    for (r = live_fft_from; r < rows; r++) {
        dsp_rtl_read_row(&dsp, r, row);
        for (b = 0u; b < SPEC_BINS; b++) if (row[b] > live_fft[b]) live_fft[b] = row[b];
    }
    live_fft_from = rows;
}

/* Count the packets decoded since the last call: CRCs, and whether each alarm
   came on the channel after the previous one (the transmitter's hop list). */
static int update_stats(void)
{
    int changed = 0;

    while (stats_seen < dsp.nlog) {
        const cap_dec_t *d = &dsp.log[stats_seen % DSP_LOG_N];
        frame_t f;

        stats_seen++;
        changed = 1;
        stats.rx++;
        if (d->crc_ok) stats.crc16++;
        if (frame_parse(d, &f) && f.crc8_ok && d->crc_ok) {
            stats.crc8++;
            if (f.cmd == FRAME_CMD_ALARM) {
                if (prev_alarm_ch >= 0) {
                    stats.hop_n++;
                    if (d->ch == (uint8_t)((prev_alarm_ch + 1) % (int)CFG_HOP_N)) stats.hop_ok++;
                }
                prev_alarm_ch = d->ch;
            }
        }
    }
    return changed;
}

/* "12.3/16.7S" -- playback position in the file */
static void update_status(void)
{
    uint32_t pos = sd_iq_pos() / (CFG_SAMPLE_RATE_HZ / 10u);
    uint32_t len = sd_iq_len() / (CFG_SAMPLE_RATE_HZ / 10u);
    char *p = plot_u32_to_str(viewer.status, pos / 10u);

    *p++ = '.';
    *p++ = (char)('0' + pos % 10u);
    *p++ = '/';
    p = plot_u32_to_str(p, len / 10u);
    *p++ = '.';
    *p++ = (char)('0' + len % 10u);
    *p++ = 'S';
    *p = '\0';
}

/* Open the capture file and start the PL on it. 0: no card / no file. */
static int play_start(void)
{
    uint32_t n;

    sd_iq_close();
    play_name = CFG_PLAY_FILE;
    if (sd_mounted && sd_iq_open(play_name, &n) != 0) {
        play_name = CFG_PLAY_FILE16;            /* the int16 file: slower than real time */
        if (sd_iq_open(play_name, &n) != 0) play_name = 0;
    }
    if (!sd_mounted || !play_name) {
        state = ST_NOFILE;
        viewer.sd_note = sd_mounted ? "NO " CFG_PLAY_FILE " ON THE CARD (K2: TEST AGAIN)"
                                    : "NO FAT CARD (K2: TEST AGAIN)";
        viewer.status[0] = '\0';
        return 0;
    }
    dsp_rtl_play_start(&dsp);
    sd_iq_play(CFG_PLAY_RATE);
    state = ST_PLAY;
    viewer.state = VSTATE_LIVE;
    viewer.cap = 0;                    /* until the first packet is captured */
    viewer.fft = live_fft;
    viewer.fft_tag = "PLAY";
    viewer.wf.row = live_row;
    viewer.wf.ctx = &live_wf;
    viewer.wf.nrows = 0u;
    viewer.wf.live = 0u;                /* top = start of the file */
    file_wf_restart();
    viewer.source = play_name;
    viewer.sd_note = play_name;
    viewer_set_progress(&viewer, 0u, 1u);
    live_fft_from = dsp_rtl_spec_rows(&dsp);
    stats_seen = 0u;
    prev_alarm_ch = -1;
    stats.rx = stats.crc16 = stats.crc8 = stats.hop_ok = stats.hop_n = 0u;
    update_status();
    return 1;
}

static void go_pause(void)
{
    sd_iq_pause(1);                    /* no samples out: the PL waits */
    dsp_rtl_live_spectrum(&dsp, 0);    /* the ring keeps its rows */
    state = ST_PAUSE;
    viewer.state = VSTATE_PAUSE;
    viewer.fft_tag = "PAUSE";
}

/* The file is over: stop everything, keep the pictures. */
static void play_end(void)
{
    live_spectra();                    /* the last rows into the FFT trace */
    live_wf.frozen = 1u;
    viewer.wf.frozen = 1u;
    viewer.wf.cursor = 0xFFFFu;
    dsp_rtl_freeze(&dsp, 1);
    dsp_rtl_live_spectrum(&dsp, 0);
    state = ST_END;
    viewer.state = VSTATE_END;
    viewer.fft_tag = "END";
    update_status();
}

static void resume_play(void)
{
    sd_iq_pause(0);
    dsp_rtl_live_spectrum(&dsp, 1);
    state = ST_PLAY;
    viewer.state = VSTATE_LIVE;
    viewer.fft_tag = "PLAY";
    live_fft_from = dsp_rtl_spec_rows(&dsp);
}

int main(void)
{
    int redraw = 1, full = 1, new_cap = 0;
    uint32_t last_draw = 0u, rate_t0 = 0u, rate_out0 = 0u;

    xil_printf("\r\n=== DF5 signal viewer ===\r\n");

    if (spi_tft_init(&spi, XPAR_TFT_TOP_0_BASEADDR, CFG_ACLK_HZ, CFG_TFT_SCLK_HZ) != 0) {
        xil_printf("ERROR: SPI TFT core not found\r\n");
        return -1;
    }

    tft_init(&tft, &spi, TFT_ROT_90);
    spi_tft_backlight(&spi, 1);
    system_ctrl_init(&sys, XPAR_SYSTEM_CTRL_TOP_0_BASEADDR);

    viewer_init(&viewer);
    if (dsp_rtl_init(&dsp, XPAR_DSP_TOP_0_BASEADDR) != 0) {
        tft_clear(&tft, TFT_BLACK);
        tft_draw_text(&tft, 10, 100, "DSP CORE NOT FOUND", TFT_RED, TFT_BLACK, 2);
        spi_tft_flush(&spi);
        return -1;
    }
    if (sd_host_init(&sd_host, XPAR_SD_HOST_TOP_0_BASEADDR) != 0) {
        tft_clear(&tft, TFT_BLACK);
        tft_draw_text(&tft, 10, 100, "SD HOST NOT FOUND", TFT_RED, TFT_BLACK, 2);
        spi_tft_flush(&spi);
        return -1;
    }
    viewer.sd = &sd_info;
    viewer.sd_fmt = &sd_fmt;
    viewer.stats = &stats;
    viewer.fft = live_fft;             /* the spectrum screens never see NULL */
    viewer.wf.row = live_row;
    viewer.wf.ctx = &live_wf;
    viewer.wf.cursor = 0xFFFFu;
    keys_init(&keys);
    tft.idle = poll_dsp;

    run_sd_test();
    if (!play_start()) viewer.mode = VIEW_SD;
    (void)millis();

    while (1) {
        static uint32_t hold_n, hold_last;
        uint32_t now = millis();
        key_action_t a = keys_poll(&keys, system_ctrl_get_buttons_raw(&sys), now);

        /*------------------------------------------------------ keys */
        if (a == KEY_BOTH && state == ST_PAUSE) {
            resume_play();
            full = redraw = 1;
        } else if (a == KEY_BOTH && state == ST_END) {
            (void)play_start();         /* the file from the start, a new waterfall */
            full = redraw = 1;
        } else if (viewer.mode == VIEW_SD && a == KEY_ZOOM) {
            /* K2 on the SD CARD screen: test the card again, play the file from the start */
            run_sd_test();
            if (play_start()) viewer.mode = VIEW_RAW;
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
                sd_format_run(&sd_fmt, &sd, &sd_host, ticks, CFG_ACLK_HZ);
                run_sd_test();          /* show the new file system */
                (void)play_start();     /* the card is empty now: NOFILE */
                full = redraw = 1;
            }
        } else if (state == ST_PLAY && a == KEY_ZOOM && viewer.mode != VIEW_SD) {
            go_pause();
            full = redraw = 1;
        } else if (a != KEY_NONE && viewer_key(&viewer, a)) {
            full = redraw = 1;
        }

        /* a file sent from the PC (tools/sd_upload.py): play it if it is the capture file */
        if (sd_mounted && sd_iq_upload_poll()) {
            if (play_start()) viewer.mode = VIEW_RAW;
            full = redraw = 1;
        }

        /*------------------------------------------------ card -> PL */
        if (state == ST_PLAY) {
            int st;

            if (sd_iq_poll()) {         /* the last sample is out: stop, keep the pictures */
                play_end();
                full = redraw = 1;
            }
            st = dsp_rtl_poll(&dsp);
            if (st == DSP_CAP_DONE) {
                dsp_rtl_read_capture(&dsp, &cap);
                dsp_rtl_rearm(&dsp);              /* waits for the next packet */
                if (!viewer.cap) full = 1;
                viewer.cap = &cap;
                new_cap = 1;
            }
            if (update_stats() && viewer.mode == VIEW_BITS) new_cap = 1;
            if (now - rate_t0 >= 1000u) {          /* samples into the DSP, thousands per s */
                uint32_t out = sd_host_out_count(&sd_host);
                stat_play_ksps = (out - rate_out0) / (now - rate_t0);
                rate_out0 = out;
                rate_t0 = now;
            }
        }

        /*---------------------------------------------------- the screen */
        if (state == ST_PLAY && now - last_draw >= CFG_LIVE_FRAME_MS) {
            update_status();
            viewer_set_progress(&viewer, sd_iq_pos(), sd_iq_len());
            if (viewer.mode == VIEW_FFT || viewer.mode == VIEW_WATERFALL || viewer.mode == VIEW_FFT_WF) {
                live_spectra();
                redraw = 1;
            } else if (new_cap) {
                redraw = 1;
            }
        }
        if (redraw) {
            if (viewer.mode == VIEW_FFT || viewer.mode == VIEW_WATERFALL || viewer.mode == VIEW_FFT_WF)
                if (viewer.wf.nrows == 0u) live_spectra();
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
