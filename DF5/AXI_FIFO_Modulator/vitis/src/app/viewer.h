/*
 * viewer.h -- the signal viewer: shows one capture (app/capture.h) with two
 * packets as screens. The capture comes from outside -- the RTL on the board
 * (hal/dsp_rtl.h), the C model on the PC (tools/host_sim/model):
 *   RAW I/Q    the input signal over time
 *   BITS       bits decoded from both packets (waveform + hex)
 *   FFT        level in dBFS vs frequency (max hold), peak marker
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

typedef struct {
    view_mode_t mode;
    zoom_t zoom[VIEW_COUNT];
    const cap_data_t *cap;     /* NULL while recording */
    uint32_t prog_done, prog_total;   /* recording progress */
    const sd_info_t *sd;       /* shown on the SD CARD screen, may be NULL */
    const sd_format_result_t *sd_fmt;
} viewer_t;

void viewer_init(viewer_t *v);

void viewer_set_mode(viewer_t *v, view_mode_t mode);

/* Apply a key action (zoom/scroll do nothing on the SD CARD screen). Returns 1 if
   the screen has to be redrawn. */
int viewer_key(viewer_t *v, key_action_t a);

/* Show this capture (NULL: back to the progress bar). */
void viewer_set_capture(viewer_t *v, const cap_data_t *cap);

/* Recording progress while there is no capture: done of total. */
void viewer_set_progress(viewer_t *v, uint32_t done, uint32_t total);

/* Redraw the current screen (capture progress until the capture is set). */
void viewer_draw(viewer_t *v, tft_t *tft);

#endif
