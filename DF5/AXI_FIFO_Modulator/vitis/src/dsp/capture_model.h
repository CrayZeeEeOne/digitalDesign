/*
 * capture_model.h -- the capture computed in C (host simulator only): the
 * demodulator chain over software I/Q, then the same recording that the RTL
 * makes on the board (dsp_capture + dsp_spectrum), into a cap_data_t.
 *
 * After CFG_WARMUP_SAMPLES the capture waits for the end of a packet, so the
 * next CFG_CAPTURE_SAMPLES samples start in a gap. The C chain has no sync /
 * CRC stage, so cap_data_t.dec[] stays empty.
 */
#ifndef CAPTURE_MODEL_H
#define CAPTURE_MODEL_H

#include <stdint.h>
#include "app/capture.h"
#include "dsp/demod_chain.h"
#include "dsp/spectrum.h"

typedef struct {
    demod_chain_t chain;
    uint8_t state;
    uint32_t count;            /* samples in the warm-up / trigger wait */
    uint32_t pos;              /* samples recorded */

    uint16_t raw_idx;
    uint32_t raw_edge;         /* first sample of the next column */
    uint8_t in_pkt;            /* d.pkt[d.npkt] is being recorded */

    uint8_t blk_rec;           /* the current block has recorded samples */
    uint16_t wf_blocks;
    uint8_t wf_row;
    uint32_t wf_acc[SPEC_BINS];
    int16_t fft_re[SPEC_FFT_N], fft_im[SPEC_FFT_N];
    uint16_t mag[SPEC_BINS];

    cap_data_t d;
} capture_model_t;

/* nco_inc / bit_inc: see demod_chain_init(). */
void capture_model_init(capture_model_t *m, uint16_t nco_inc, uint16_t bit_inc);

/* One block of interleaved I/Q (n_samples complex samples). */
void capture_model_block(capture_model_t *m, const int16_t *iq, uint32_t n_samples);

int capture_model_done(const capture_model_t *m);

#endif
