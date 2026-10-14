/*
 * spectrum.h -- one spectrum column from a block of I/Q: Hann window,
 * SPEC_FFT_N-point FFT, log magnitude of the SPEC_BINS central bins.
 *
 * With Fs = 4.5 MHz: ~17.6 kHz per bin, +-562 kHz shown.
 */
#ifndef SPECTRUM_H
#define SPECTRUM_H

#include <stdint.h>

#define SPEC_FFT_N  256
#define SPEC_BINS   64

/*
 * iq:  at least SPEC_FFT_N interleaved I/Q samples (only the first SPEC_FFT_N are used).
 * re, im: SPEC_FFT_N-element work buffers.
 * col: SPEC_BINS values, ~16*log2(|X|) (about 0.38 dB per step); col[0] is the lowest
 *      frequency, col[SPEC_BINS/2] the center frequency.
 */
void spectrum_column(const int16_t *iq, int16_t *re, int16_t *im, uint8_t *col);

#endif
