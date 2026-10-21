#include "dsp/dsp_math.h"
#include "dsp/dsp_tables.h"

int16_t sin_q15(uint16_t phase)
{
    uint16_t idx = (phase >> 6) & 1023u;
    uint16_t q = idx >> 8;
    uint16_t o = idx & 255u;

    switch (q) {
    case 0: return  dsp_sin_q15[o];
    case 1: return  dsp_sin_q15[256u - o];
    case 2: return -dsp_sin_q15[o];
    default: return -dsp_sin_q15[256u - o];
    }
}
