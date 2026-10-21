#include "dsp/decimator.h"

int decimator_push(decimator_t *d, int16_t i, int16_t q, int16_t *di, int16_t *dq)
{
    d->i_acc += i;
    d->q_acc += q;
    if (++d->ctr < DECIM_R) return 0;

    *di = (int16_t)(d->i_acc / DECIM_R);
    *dq = (int16_t)(d->q_acc / DECIM_R);
    d->i_acc = 0;
    d->q_acc = 0;
    d->ctr = 0u;
    return 1;
}
