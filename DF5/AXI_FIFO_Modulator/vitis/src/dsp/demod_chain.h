/*
 * demod_chain.h -- the whole demodulator, one input sample at a time:
 *
 *   I/Q -> nco_mixer -> decimator (/16) -> discriminator -> burst_detect
 *                                                        -> bit_decoder
 *
 * Every stage's output is returned, so the capture and the plots can show
 * any point of the chain (the same stages as rtl_demod_plots.html).
 */
#ifndef DEMOD_CHAIN_H
#define DEMOD_CHAIN_H

#include <stdint.h>
#include "dsp/nco_mixer.h"
#include "dsp/decimator.h"
#include "dsp/discriminator.h"
#include "dsp/burst_detect.h"
#include "dsp/bit_decoder.h"

typedef struct {
    int16_t i, q;              /* input */
    int16_t mi, mq;            /* after the mixer */

    uint8_t dec_valid;         /* the fields below are valid only when set */
    uint8_t burst_rise;        /* a burst started on this decimated sample */
    uint32_t dec_count;        /* index of this decimated sample (from 1) */
    int16_t di, dq;            /* after the decimator */
    int32_t dphi;              /* discriminator */
    uint32_t pavg, noise;      /* burst detector */
    int16_t favg, dev;         /* bit decoder */
    uint8_t flags;             /* DEMOD_F_* */
} demod_sample_t;

typedef struct {
    nco_mixer_t nco;
    decimator_t dec;
    discriminator_t disc;
    burst_detect_t bd;
    bit_decoder_t bit;
    uint32_t dec_count;
} demod_chain_t;

void demod_chain_init(demod_chain_t *c, uint16_t nco_inc);
void demod_chain_step(demod_chain_t *c, int16_t i, int16_t q, demod_sample_t *o);

#endif
