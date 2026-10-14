/*
 * view_spectrum.h -- spectrogram and waterfall screens (P0/P1 in the view list).
 *
 * A full-resolution spectrogram does not fit in BRAM, so these screens are
 * drawn straight to the panel from new data: wait for a burst, then one pixel
 * column (spectrogram) or one line per LIVE_WF_EVERY columns (waterfall) per
 * FFT, until the plot is full. The picture then lives only in the panel.
 */
#ifndef VIEW_SPECTRUM_H
#define VIEW_SPECTRUM_H

#include <stdint.h>
#include "gfx/tft.h"
#include "dsp/spectrum.h"

#define LIVE_PRE       16      /* columns kept before the burst start */
#define LIVE_WF_TRACES 24      /* waterfall lines */
#define LIVE_WF_EVERY  6       /* columns averaged per waterfall line */
#define LIVE_TIMEOUT   1200    /* blocks to wait for a burst */

typedef struct {
    tft_t *tft;
    uint8_t state;             /* LIVE_OFF / LIVE_ARMED / LIVE_DRAW */
    uint8_t spectrogram;       /* 1: spectrogram, 0: waterfall */
    uint8_t skip;              /* bursts to skip before the shown one */
    uint16_t x;                /* columns drawn so far */
    uint16_t wait;             /* blocks waited for a burst */
    uint8_t lo;                /* color/height scale floor = noise level */
    uint8_t pre[LIVE_PRE][SPEC_BINS];
    uint8_t pre_wr;
    uint16_t wf_acc[SPEC_BINS];
    int16_t fft_re[SPEC_FFT_N], fft_im[SPEC_FFT_N];
} live_spectrum_t;

/* Draw the axes and start waiting for burst number skip (0 = the next one). */
void live_spectrum_arm(live_spectrum_t *l, tft_t *tft, int spectrogram, uint8_t skip);
void live_spectrum_stop(live_spectrum_t *l);
int  live_spectrum_active(const live_spectrum_t *l);

/* A burst started in the data passed so far. */
void live_spectrum_on_burst(live_spectrum_t *l);

/* One block of new I/Q (at least SPEC_FFT_N samples). */
void live_spectrum_feed(live_spectrum_t *l, const int16_t *iq, uint32_t n_samples);

#endif
