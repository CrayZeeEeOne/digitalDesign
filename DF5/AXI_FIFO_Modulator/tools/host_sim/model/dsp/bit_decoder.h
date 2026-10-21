/*
 * bit_decoder.h -- bits out of the instantaneous frequency (dphi) of a burst.
 *
 *   1. AFC: favg = slow average of dphi, the slicer threshold;
 *   2. slicer: bit = 1 when the frequency is above favg (dphi below it: the
 *      discriminator output has the opposite sign of the frequency);
 *   3. bit clock: a 16-bit phase advanced by bit_inc per sample; a decision is
 *      taken when it wraps (mid-bit); on every slicer transition the phase is
 *      pulled towards 1/2 (transitions sit between decisions), by 1/4 of the error.
 *
 * Same steps as demod_bit_decoder.sv 1-3; no preamble/sync-word search and no
 * CRC yet (the test signal has no sync word).
 */
#ifndef BIT_DECODER_H
#define BIT_DECODER_H

#include <stdint.h>

typedef struct {
    uint16_t bit_inc;          /* 2^16 * bitrate / sample rate */
    uint16_t phase;            /* bit clock */
    int32_t favg;              /* AFC, Q8 */
    uint8_t last;              /* previous slicer output */
} bit_decoder_t;

void bit_decoder_init(bit_decoder_t *b, uint16_t bit_inc);

/* Restart at the beginning of a burst. */
void bit_decoder_start(bit_decoder_t *b);

/* One sample of dphi. Returns 1 when *bit holds a new decision. */
int bit_decoder_step(bit_decoder_t *b, int32_t dphi, uint8_t *bit);

#endif
