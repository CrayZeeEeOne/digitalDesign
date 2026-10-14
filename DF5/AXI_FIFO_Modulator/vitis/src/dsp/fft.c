#include "dsp/fft.h"
#include "dsp/dsp_math.h"

void fft_q15(int16_t *re, int16_t *im, uint16_t n)
{
    uint16_t i, j, k, len;

    for (i = 1u, j = 0u; i < n; i++) {
        uint16_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            int16_t t;
            t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }

    for (len = 2u; len <= n; len <<= 1) {
        uint16_t half = len >> 1;
        uint16_t dph = (uint16_t)(65536u / len);

        for (i = 0u; i < n; i += len) {
            for (k = 0u; k < half; k++) {
                uint16_t ph = (uint16_t)(k * dph);
                int32_t wr = sin_q15((uint16_t)(ph + 16384u));
                int32_t wi = -sin_q15(ph);
                uint16_t a = (uint16_t)(i + k);
                uint16_t b = (uint16_t)(a + half);
                int32_t tr = (re[b] * wr - im[b] * wi) >> 15;
                int32_t ti = (re[b] * wi + im[b] * wr) >> 15;

                re[b] = (int16_t)((re[a] - tr) >> 1);
                im[b] = (int16_t)((im[a] - ti) >> 1);
                re[a] = (int16_t)((re[a] + tr) >> 1);
                im[a] = (int16_t)((im[a] + ti) >> 1);
            }
        }
    }
}
