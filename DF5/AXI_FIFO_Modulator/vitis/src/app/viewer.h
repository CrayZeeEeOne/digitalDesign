/*
 * viewer.h -- the signal viewer: the screens over the signal, in three states:
 *
 *   LIVE    real time: the PL records continuously, the screens are redrawn as
 *           fast as the TFT takes them (no zoom; K2 pauses)
 *   PAUSE   the last live picture frozen: zoom and scroll work (K1+K2: live again)
 *   STATIC  one finished capture (replay of a file from the SD card; on the PC
 *           the C model of tools/host_sim)
 *
 * Screens:
 *   RAW I/Q    the input signal over time
 *   BITS       bits decoded from the packets (waveform, hex, CRC)
 *   FFT        level in dBFS vs frequency, peak marker
 *   WATERFALL  frequency vs time
 *   SD CARD    result of the microSD test (app/sd_test.h)
 * Each plot keeps its own zoom (x1..x16) and position (app/keys.h for the keys).
 */
#ifndef VIEWER_H
#define VIEWER_H

#include <stdint.h>
#include "gfx/tft.h"
#include "app/capture.h"
#include "app/keys.h"
#include "app/zoom.h"
#include "app/view_freq.h"
#include "app/sd_test.h"
#include "app/sd_format.h"

typedef enum {
    VIEW_RAW = 0,
    VIEW_BITS,
    VIEW_FFT,
    VIEW_WATERFALL,
    VIEW_SD,
    VIEW_COUNT
} view_mode_t;

typedef enum {
    VSTATE_STATIC = 0,
    VSTATE_LIVE,
    VSTATE_PAUSE
} view_state_t;

typedef struct {
    view_mode_t mode;
    view_state_t state;
    zoom_t zoom[VIEW_COUNT];
    const cap_data_t *cap;     /* RAW / BITS (and STATIC spectra); NULL while recording */
    const uint8_t *fft;        /* FFT trace, SPEC_BINS levels */
    const char *fft_tag;
    wf_src_t wf;               /* WATERFALL rows */
    uint32_t prog_done, prog_total;   /* recording progress (STATIC) */
    const char *source;        /* where the signal comes from, shown in the header */
    const sd_info_t *sd;       /* shown on the SD CARD screen, may be NULL */
    const sd_format_result_t *sd_fmt;
} viewer_t;

void viewer_init(viewer_t *v);

void viewer_set_mode(viewer_t *v, view_mode_t mode);

/* Apply a key action: screen change always; zoom / scroll only outside LIVE and
   not on the SD CARD screen. Returns 1 if the screen has to be redrawn. */
int viewer_key(viewer_t *v, key_action_t a);

/* STATIC: show this finished capture (FFT = its max hold, waterfall = its 40 rows);
   NULL: back to the progress bar. */
void viewer_use_capture(viewer_t *v, const cap_data_t *cap);

/* Recording progress while there is no capture: done of total. */
void viewer_set_progress(viewer_t *v, uint32_t done, uint32_t total);

/* Redraw. full = 1: clear the screen and draw the frame too (screen or state
   changed); 0: only the contents, over the old picture (live refresh). */
void viewer_draw(viewer_t *v, tft_t *tft, int full);

#endif
