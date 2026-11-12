/*
 * view_freq.h -- screens over frequency (spectrum-analyzer style):
 *   FFT        level in dBFS vs frequency, with a peak marker;
 *   WATERFALL  frequency (x) vs time (y), color = level;
 *   FFT+WF     both, one above the other.
 * The zoom window counts in spectrum points (SPEC_BINS = 128 over the whole
 * 4.5 MHz band, 35 kHz each). Drawn over the old
 * picture without clearing it (columns / rows sent in one window): no flicker
 * when redrawn many times a second.
 */
#ifndef VIEW_FREQ_H
#define VIEW_FREQ_H

#include "gfx/tft.h"
#include "app/capture.h"
#include "app/zoom.h"

#define VIEW_FREQ_POINTS SPEC_BINS

/*
 * Rows of the waterfall, top to bottom: from a capture (40 rows, oldest at the
 * top) or the live ring of the PL (newest at the top).
 */
typedef struct {
    uint16_t nrows;
    const uint8_t *(*row)(void *ctx, uint16_t i);   /* SPEC_BINS levels of row i */
    void *ctx;
    uint32_t span_ms10;        /* time from the top row to the bottom row, 0.1 ms */
    uint8_t live;              /* top = now; else top = start of the capture / the file */
    uint16_t cursor;           /* row drawn with a white line (playback position), 0xFFFF = none */
    uint8_t frozen;            /* the rows do not change any more: drawn only with full */
} wf_src_t;

/* fft: SPEC_BINS levels; tag: text in the corner ("MAX HOLD", "LIVE"). */
void view_fft(tft_t *tft, const uint8_t *fft, const char *tag, const zoom_t *z, int full);

/* c: packet marks (NULL: none). */
void view_waterfall(tft_t *tft, const wf_src_t *s, const cap_data_t *c, const zoom_t *z, int full);

/* FFT (top) and waterfall (bottom) on one screen, the same frequency scale. */
void view_fft_wf(tft_t *tft, const uint8_t *fft, const char *tag, const wf_src_t *s, const zoom_t *z, int full);

#endif
