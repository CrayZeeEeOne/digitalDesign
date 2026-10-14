/*
 * nco_mixer.h -- spectrum shift: I/Q times e^{+j*theta}, theta advances by
 * inc per sample (2^16 = 2*pi, so f_nco = inc / 2^16 * Fs).
 * RTL counterpart: demod_nco_mixer.sv.
 */
#ifndef NCO_MIXER_H
#define NCO_MIXER_H

#include <stdint.h>

typedef struct {
    uint16_t phase;
    uint16_t inc;
} nco_mixer_t;

void nco_mixer_init(nco_mixer_t *m, uint16_t inc);
void nco_mixer_step(nco_mixer_t *m, int16_t i, int16_t q, int16_t *mi, int16_t *mq);

#endif
