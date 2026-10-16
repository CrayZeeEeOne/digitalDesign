/*
 * capture.h -- one fixed recording for the static screens.
 *
 * After CFG_WARMUP_SAMPLES the capture waits for the end of a packet, so the
 * next CFG_CAPTURE_SAMPLES samples hold two whole packets with gaps around them.
 * It keeps:
 *   raw[]    min/max of input I and Q in CAP_RAW_COLS columns, in steps of
 *            2^CAP_RAW_SHIFT (int8, saturated); raw samples are not kept
 *   pkt[]    bits decoded from up to CAP_PKTS packets
 *   fft[]    spectrum of the capture: max hold over the waterfall rows (spec_log levels)
 *   wf[][]   waterfall: CAP_WF_ROWS spectra, one per CFG_CAPTURE_SAMPLES / CAP_WF_ROWS
 * Nothing here draws.
 */
#ifndef CAPTURE_H
#define CAPTURE_H

#include <stdint.h>
#include "config.h"
#include "dsp/demod_chain.h"
#include "dsp/spectrum.h"

#define CAP_RAW_COLS  384
#define CAP_WF_ROWS   40
#define CAP_PKTS      2
#define CAP_PKT_BITS  256
#define CAP_RAW_SHIFT 6        /* raw[] step: 64 ADC units, range +-8128 */

typedef struct {
    int8_t i_lo, i_hi, q_lo, q_hi;
} cap_raw_t;

typedef struct {
    uint32_t start, end;       /* burst start / end, samples from the capture start */
    uint32_t first_bit;        /* sample of the first bit decision */
    uint16_t nbits;
    uint8_t bits[CAP_PKT_BITS / 8];    /* first bit = MSB of bits[0] */
} cap_pkt_t;

typedef struct {
    uint8_t state;
    uint32_t count;            /* samples in the warm-up / trigger wait */
    uint32_t pos;              /* samples recorded */

    cap_raw_t raw[CAP_RAW_COLS];
    uint16_t raw_idx;
    uint32_t raw_edge;         /* first sample of the next column */

    cap_pkt_t pkt[CAP_PKTS];
    uint8_t npkt;              /* packets finished */
    uint8_t in_pkt;            /* pkt[npkt] is being recorded */

    uint8_t blk_rec;           /* the current block has recorded samples */
    uint16_t wf_blocks;
    uint8_t wf_row;
    uint32_t wf_acc[SPEC_BINS];
    uint8_t fft[SPEC_BINS];
    uint8_t wf[CAP_WF_ROWS][SPEC_BINS];
    int16_t fft_re[SPEC_FFT_N], fft_im[SPEC_FFT_N];
    uint16_t mag[SPEC_BINS];
} capture_t;

void capture_init(capture_t *c);

/* After the demodulator processed one input sample. */
void capture_sample(capture_t *c, const demod_sample_t *s);

/* After a whole block of samples (spectrum of the block). */
void capture_block(capture_t *c, const int16_t *iq, uint32_t n_samples);

int capture_done(const capture_t *c);

/* 0..total progress for a progress bar. */
uint32_t capture_progress(const capture_t *c, uint32_t total);

/* Bit k of a packet (0/1). */
static inline uint8_t cap_pkt_bit(const cap_pkt_t *p, uint16_t k)
{
    return (uint8_t)((p->bits[k >> 3] >> (7u - (k & 7u))) & 1u);
}

#endif
