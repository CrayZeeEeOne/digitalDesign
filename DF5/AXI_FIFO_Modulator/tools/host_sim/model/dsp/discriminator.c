#include "dsp/discriminator.h"

int32_t discriminator_step(discriminator_t *d, int16_t i, int16_t q)
{
    int32_t dphi = (int32_t)i * d->prev_q - (int32_t)q * d->prev_i;

    dphi >>= 12;
    if (dphi > 32767) dphi = 32767;
    if (dphi < -32768) dphi = -32768;

    d->prev_i = i;
    d->prev_q = q;
    return dphi;
}
