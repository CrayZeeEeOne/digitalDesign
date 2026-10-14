/* fft.h -- in-place radix-2 DIT FFT on Q15 data, scaled by 1/2 per stage. */
#ifndef FFT_H
#define FFT_H

#include <stdint.h>

/* n: power of two, at most 32768. */
void fft_q15(int16_t *re, int16_t *im, uint16_t n);

#endif
