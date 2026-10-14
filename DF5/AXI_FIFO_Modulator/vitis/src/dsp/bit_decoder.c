#include "dsp/bit_decoder.h"
#include "dsp/dsp_math.h"

uint8_t bit_decoder_step(bit_decoder_t *b, int32_t dphi, int burst, int burst_rise, uint32_t dec_count)
{
    uint8_t flags = 0u;
    uint8_t was_pkt = b->pkt_active;

    if (burst_rise) b->burst_start = dec_count;

    b->favg = (int16_t)((7 * (int32_t)b->favg + dphi) / 8);
    b->dev = (int16_t)((15 * (int32_t)b->dev + abs32(dphi - b->favg)) / 16);

    b->pkt_active = 0u;
    if (burst) {
        uint32_t age = dec_count - b->burst_start;
        flags |= DEMOD_F_BURST;
        if (age > 8u)  flags |= DEMOD_F_SYNC;
        if (age > 16u) flags |= DEMOD_F_PRE;
        if (age > 28u) { b->pkt_active = 1u; flags |= DEMOD_F_PKT; }
    }

    if (was_pkt && !b->pkt_active) flags |= DEMOD_F_RES;
    return flags;
}
