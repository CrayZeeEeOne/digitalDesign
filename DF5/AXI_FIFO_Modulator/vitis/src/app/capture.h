/*
 * capture.h -- one fixed recording of the demodulator chain for the static plots.
 *
 * After CFG_WARMUP_SAMPLES the next CFG_CAPTURE_SAMPLES samples are split into
 * CAP_COLS columns; each column keeps min/max (or the last value) of every
 * stage. Raw samples are not kept. Nothing here draws.
 */
#ifndef CAPTURE_H
#define CAPTURE_H

#include <stdint.h>
#include "dsp/demod_chain.h"

#define CAP_COLS          160
#define CAP_CONST_POINTS  64

/* Channels of cap_col_t.lo/hi. */
enum { CAP_IN_I = 0, CAP_IN_Q, CAP_MIX_I, CAP_MIX_Q, CAP_DEC_I, CAP_DEC_Q, CAP_CH_COUNT };

typedef struct {
    int16_t lo[CAP_CH_COUNT], hi[CAP_CH_COUNT];
    int16_t dphi_lo, dphi_hi;
    int16_t favg, dev;
    uint16_t pavg, noise;      /* threshold is derived from noise */
    uint8_t flags;             /* DEMOD_F_*, OR over the column */
} cap_col_t;

typedef struct {
    cap_col_t col[CAP_COLS];
    uint16_t col_idx;
    uint32_t col_edge;         /* first sample of the next column */

    int16_t cons_i[CAP_CONST_POINTS], cons_q[CAP_CONST_POINTS];
    uint16_t cons_n;

    uint32_t sample_count;     /* input samples seen, warm-up included */
    uint32_t burst_total;      /* bursts that started inside the capture */
    uint8_t done;
} capture_t;

void capture_init(capture_t *c);

/* Before each input sample: the column it belongs to, or NULL (warm-up / finished). */
cap_col_t *capture_slot(capture_t *c);

/* After the demodulator processed that sample. col: what capture_slot returned. */
void capture_put(capture_t *c, cap_col_t *col, const demod_sample_t *s);

/* 0..total progress for a progress bar. */
uint32_t capture_progress(const capture_t *c, uint32_t total);

#endif
