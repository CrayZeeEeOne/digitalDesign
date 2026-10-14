#include "dsp/nco_mixer.h"
#include "dsp/dsp_math.h"

void nco_mixer_init(nco_mixer_t *m, uint16_t inc)
{
    m->phase = 0u;
    m->inc = inc;
}

void nco_mixer_step(nco_mixer_t *m, int16_t i, int16_t q, int16_t *mi, int16_t *mq)
{
    int16_t lo_i = sin_q15((uint16_t)(m->phase + 16384u));
    int16_t lo_q = sin_q15(m->phase);

    m->phase += m->inc;

    *mi = (int16_t)(((int32_t)i * lo_i - (int32_t)q * lo_q) >> 15);
    *mq = (int16_t)(((int32_t)i * lo_q + (int32_t)q * lo_i) >> 15);
}
