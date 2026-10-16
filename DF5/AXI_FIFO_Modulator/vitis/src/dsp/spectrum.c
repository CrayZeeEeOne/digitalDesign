#include "dsp/spectrum.h"
#include "dsp/dsp_math.h"
#include "dsp/dsp_tables.h"
#include "dsp/fft.h"

uint8_t spec_log(uint32_t x)
{
    uint32_t n = 0u;
    uint32_t frac;

    if (x == 0u) return 0u;
    while ((x >> n) > 1u) n++;
    frac = (n >= 4u) ? (x >> (n - 4u)) & 15u : (x << (4u - n)) & 15u;
    n = n * 16u + frac;
    return (uint8_t)(n > 255u ? 255u : n);
}

int16_t spec_log_to_ddb(uint8_t l)
{
    /* 20*log10(2)/16 dB per step = 0.3763 dB ~ 241/64 * 0.1 dB */
    return (int16_t)(((int32_t)l - SPEC_LOG_0DBFS) * 241 / 64);
}

void spectrum_mag(const int16_t *iq, int16_t *re, int16_t *im, uint16_t *mag)
{
    uint16_t n;

    for (n = 0u; n < SPEC_FFT_N; n++) {
        int32_t w = dsp_hann_q15[n * (DSP_FFT_N / SPEC_FFT_N) + (DSP_FFT_N / SPEC_FFT_N / 2)];
        re[n] = (int16_t)(((int32_t)iq[2u * n] * w) >> 15);
        im[n] = (int16_t)(((int32_t)iq[2u * n + 1u] * w) >> 15);
    }

    fft_q15(re, im, SPEC_FFT_N);

    for (n = 0u; n < SPEC_BINS; n++) {
        uint16_t k = (uint16_t)((n - SPEC_BINS / 2u) & (SPEC_FFT_N - 1u));
        mag[n] = clamp_u16((uint32_t)(abs32(re[k]) + abs32(im[k])));
    }
}
