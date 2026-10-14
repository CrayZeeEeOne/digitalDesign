#include "dsp/burst_detect.h"
#include "dsp/dsp_math.h"

void burst_detect_init(burst_detect_t *b)
{
    b->pavg = 600u;
    b->noise = 600u;
    b->burst = 0u;
    b->hang = 0u;
}

uint32_t burst_threshold(uint32_t noise)
{
    uint32_t th = noise + (noise >> 1);
    if (th < 700u) th = 700u;
    if (th > 4095u) th = 4095u;
    return th;
}

int burst_detect_step(burst_detect_t *b, int16_t i, int16_t q)
{
    uint8_t was_burst = b->burst;
    uint32_t pwr = (uint32_t)abs32(i) + (uint32_t)abs32(q);

    b->pavg = (b->pavg * 15u + pwr) >> 4;
    if (!b->burst)
        b->noise = (b->noise * 31u + (b->pavg < 300u ? 300u : b->pavg)) >> 5;

    if (b->pavg > burst_threshold(b->noise)) {
        b->burst = 1u;
        b->hang = BURST_HANG;
    } else if (b->hang != 0u) {
        b->hang--;
    } else {
        b->burst = 0u;
    }

    return b->burst && !was_burst;
}
