/*
 * view_freq.h -- screens over frequency (spectrum-analyzer style):
 *   FFT        level in dBFS vs frequency (max hold over the capture), with a
 *              peak marker;
 *   WATERFALL  frequency (x) vs time (y, capture start at the top), color = level.
 * The zoom window counts in spectrum bins (SPEC_BINS).
 */
#ifndef VIEW_FREQ_H
#define VIEW_FREQ_H

#include "gfx/tft.h"
#include "app/capture.h"
#include "app/zoom.h"

#define VIEW_FREQ_POINTS SPEC_BINS

void view_fft(tft_t *tft, const capture_t *c, const zoom_t *z);
void view_waterfall(tft_t *tft, const capture_t *c, const zoom_t *z);

#endif
