#include "dsp/spectrum.h"
#include "dsp/dsp_math.h"
#include "dsp/dsp_tables.h"
#include "dsp/fft.h"

/* ~16*log2(x), clamped to 0..255. */
static uint8_t log2_u8(uint32_t x)
{
    uint32_t n = 0u;
    uint32_t frac;

    if (x == 0u) return 0u;
    while ((x >> n) > 1u) n++;
    frac = (n >= 4u) ? (x >> (n - 4u)) & 15u : (x << (4u - n)) & 15u;
    n = n * 16u + frac;
    return (uint8_t)(n > 255u ? 255u : n);
}

void spectrum_column(const int16_t *iq, int16_t *re, int16_t *im, uint8_t *col)
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
        col[n] = log2_u8((uint32_t)(abs32(re[k]) + abs32(im[k])));
    }
}
