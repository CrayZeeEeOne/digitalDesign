/*
 * decimator.h -- decimation by DECIM_R: average of DECIM_R samples
 * (integrate-and-dump, i.e. a CIC of order 1).
 * RTL counterpart: demod_cic3.sv (order 3, so the responses differ).
 */
#ifndef DECIMATOR_H
#define DECIMATOR_H

#include <stdint.h>

#define DECIM_R 16

typedef struct {
    int32_t i_acc;
    int32_t q_acc;
    uint8_t ctr;
} decimator_t;

/* Returns 1 when *di / *dq hold a new decimated sample. */
int decimator_push(decimator_t *d, int16_t i, int16_t q, int16_t *di, int16_t *dq);

#endif
