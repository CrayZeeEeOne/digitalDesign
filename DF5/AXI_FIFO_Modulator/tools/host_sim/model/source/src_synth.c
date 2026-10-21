#include "source/src_synth.h"
#include "config.h"
#include "dsp/dsp_math.h"

static void src_synth_read(iq_source_t *base, int16_t *iq, uint32_t n)
{
    src_synth_t *s = (src_synth_t *)base;
    uint32_t k;

    for (k = 0; k < n; k++) {
        uint32_t sym = s->sym_count % (SRC_PKT_SYMS + SRC_GAP_SYMS);
        int16_t i = 0;
        int16_t q = 0;

        s->sym_phase += CFG_BITRATE;
        if (s->sym_phase >= CFG_SAMPLE_RATE_HZ) {
            s->sym_phase -= CFG_SAMPLE_RATE_HZ;
            s->sym_count += 1u;
        }

        if (sym < SRC_PKT_SYMS) {
            int bit = (sym < SRC_PREAMBLE) ? (int)(sym & 1u)
                                           : (int)(((sym * 0x9E3779B1u) >> 29) & 1u);
            uint16_t ph;

            s->phase += (uint32_t)(SRC_CARRIER_INC + (bit ? SRC_DEV_INC : -SRC_DEV_INC));
            ph = (uint16_t)s->phase;
            i = (int16_t)(((int32_t)sin_q15((uint16_t)(ph + 16384u)) * SRC_AMP) >> 15);
            q = (int16_t)(((int32_t)sin_q15(ph) * SRC_AMP) >> 15);
        }

        s->lfsr ^= s->lfsr << 13;
        s->lfsr ^= s->lfsr >> 17;
        s->lfsr ^= s->lfsr << 5;
        i = (int16_t)(i + (int16_t)(s->lfsr & 255u) - 128);
        q = (int16_t)(q + (int16_t)((s->lfsr >> 8) & 255u) - 128);

        iq[2u * k] = i;
        iq[2u * k + 1u] = q;
    }
}

void src_synth_init(src_synth_t *s)
{
    s->base.read = src_synth_read;
    s->phase = 0u;
    s->sym_phase = 0u;
    s->sym_count = 0u;
    s->lfsr = 0x12345678u;
}
