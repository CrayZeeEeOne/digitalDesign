/*
 * viewer.h -- the graph viewer application: runs the demodulator chain over
 * incoming I/Q, records one capture, and shows it as 12 screens in the order
 * of vivado/sources/sim_data/rtl_demod_plots.html.
 */
#ifndef VIEWER_H
#define VIEWER_H

#include <stdint.h>
#include "gfx/tft.h"
#include "dsp/demod_chain.h"
#include "app/capture.h"
#include "app/view_spectrum.h"

typedef enum {
    VIEW_INPUT_IQ = 0,
    VIEW_PKT0_SPECTRO,
    VIEW_PKT0_WATERFALL,
    VIEW_PKT1_SPECTRO,
    VIEW_PKT1_WATERFALL,
    VIEW_MIXER_IQ,
    VIEW_CIC_IQ,
    VIEW_CONSTELLATION,
    VIEW_DPHI,
    VIEW_POWER,
    VIEW_BITDEC,
    VIEW_DECODER,
    VIEW_COUNT
} view_mode_t;

typedef struct {
    view_mode_t mode;
    demod_chain_t chain;
    capture_t cap;
    live_spectrum_t live;
} viewer_t;

void viewer_init(viewer_t *v);

void viewer_set_mode(viewer_t *v, view_mode_t mode);
void viewer_next(viewer_t *v);
void viewer_prev(viewer_t *v);

void viewer_process_block(viewer_t *v, const int16_t *iq, uint32_t n_samples);

/* The capture is complete. */
int viewer_done(const viewer_t *v);

/* The viewer needs more input blocks (capture running or a spectrum screen drawing). */
int viewer_busy(const viewer_t *v);

/* Redraw the current screen (capture progress until the capture is done). */
void viewer_draw(viewer_t *v, tft_t *tft);

#endif
