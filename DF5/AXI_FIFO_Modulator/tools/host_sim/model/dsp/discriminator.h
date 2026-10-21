/*
 * discriminator.h -- FM discriminator: cross product of neighbouring samples,
 * Im(z[n] * conj(z[n-1])) >> 12, saturated to the int16 range. Proportional to
 * the instantaneous frequency while the amplitude is constant.
 * RTL counterpart: demod_discriminator.sv (exact angle via CORDIC).
 */
#ifndef DISCRIMINATOR_H
#define DISCRIMINATOR_H

#include <stdint.h>

typedef struct {
    int16_t prev_i;
    int16_t prev_q;
} discriminator_t;

int32_t discriminator_step(discriminator_t *d, int16_t i, int16_t q);

#endif
