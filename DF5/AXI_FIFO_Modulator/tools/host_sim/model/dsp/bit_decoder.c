#include "dsp/bit_decoder.h"

#define AFC_SHIFT 6            /* favg += (dphi - favg) / 64 */

void bit_decoder_init(bit_decoder_t *b, uint16_t bit_inc)
{
    b->bit_inc = bit_inc;
    bit_decoder_start(b);
}

void bit_decoder_start(bit_decoder_t *b)
{
    b->phase = 0x8000u;
    b->favg = 0;
    b->last = 0u;
}

int bit_decoder_step(bit_decoder_t *b, int32_t dphi, uint8_t *bit)
{
    uint8_t s;
    uint16_t prev_phase = b->phase;

    b->favg += ((dphi << 8) - b->favg) >> AFC_SHIFT;
    s = (uint8_t)((dphi << 8) < b->favg);

    if (s != b->last) {
        /* transition: the phase should be at 1/2 here */
        int32_t err = (int32_t)b->phase - 0x8000;
        b->phase = (uint16_t)(b->phase - err / 4);
        b->last = s;
        prev_phase = b->phase;
    }

    b->phase = (uint16_t)(b->phase + b->bit_inc);
    if (b->phase < prev_phase) {       /* wrapped: middle of a bit */
        *bit = s;
        return 1;
    }
    return 0;
}
