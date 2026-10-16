/*
 * demod_chain.h -- the whole demodulator, one input sample at a time:
 *
 *   I/Q -> nco_mixer -> decimator (/16) -> discriminator -> burst_detect
 *                                                        -> bit_decoder
 *
 * Every stage's output is returned, so the capture can record any point of
 * the chain.
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
    int16_t di, dq;            /* after the decimator */
    int32_t dphi;              /* discriminator */
    uint8_t burst;             /* inside a packet */
    uint8_t burst_rise;        /* the packet started on this sample */
    uint8_t burst_fall;        /* the packet ended on this sample */
    uint8_t bit_valid;         /* a bit decision was taken on this sample */
    uint8_t bit;
} demod_sample_t;

typedef struct {
    nco_mixer_t nco;
    decimator_t dec;
    discriminator_t disc;
    burst_detect_t bd;
    bit_decoder_t bit;
} demod_chain_t;

void demod_chain_init(demod_chain_t *c, uint16_t nco_inc, uint16_t bit_inc);
void demod_chain_step(demod_chain_t *c, int16_t i, int16_t q, demod_sample_t *o);

#endif
