/*
 * viewer.h -- the signal viewer application: runs the demodulator chain over
 * incoming I/Q, records one capture with two packets, and shows it as four
 * screens:
 *   RAW I/Q    the input signal over time
 *   BITS       bits decoded from both packets (waveform + hex)
 *   FFT        level in dBFS vs frequency (max hold), peak marker
 *   WATERFALL  frequency vs time
 * Each screen keeps its own zoom (x1..x16) and position (app/keys.h for the keys).
 */
#ifndef VIEWER_H
#define VIEWER_H

#include <stdint.h>
#include "gfx/tft.h"
#include "dsp/demod_chain.h"
#include "app/capture.h"
#include "app/keys.h"
#include "app/zoom.h"

typedef enum {
    VIEW_RAW = 0,
    VIEW_BITS,
    VIEW_FFT,
    VIEW_WATERFALL,
    VIEW_COUNT
} view_mode_t;

typedef struct {
    view_mode_t mode;
    zoom_t zoom[VIEW_COUNT];
    demod_chain_t chain;
    capture_t cap;
} viewer_t;

void viewer_init(viewer_t *v);

void viewer_set_mode(viewer_t *v, view_mode_t mode);

/* Apply a key action. Returns 1 if the screen has to be redrawn. */
int viewer_key(viewer_t *v, key_action_t a);

void viewer_process_block(viewer_t *v, const int16_t *iq, uint32_t n_samples);

/* The capture is complete (the viewer needs no more input). */
int viewer_done(const viewer_t *v);

/* Redraw the current screen (capture progress until the capture is done). */
void viewer_draw(viewer_t *v, tft_t *tft);

#endif
