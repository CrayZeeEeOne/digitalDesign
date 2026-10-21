/*
 * spectrum.h -- spectrum of a block of I/Q: Hann window, SPEC_FFT_N-point FFT,
 * magnitude of the SPEC_BINS central bins.
 *
 * With Fs = 4.5 MHz: ~17.6 kHz per bin, +-1.125 MHz shown.
 * Levels: spec_log() gives ~16*log2(|X|) (0.376 dB per step); 0 dBFS (a
 * full-scale complex tone) is SPEC_LOG_0DBFS.
 */
#ifndef SPECTRUM_H
#define SPECTRUM_H

#include <stdint.h>
#include "config.h"            /* SPEC_FFT_N, SPEC_BINS, SPEC_LOG_0DBFS */

/*
 * iq:  at least SPEC_FFT_N interleaved I/Q samples (the first SPEC_FFT_N are used).
 * re, im: SPEC_FFT_N-element work buffers.
 * mag: SPEC_BINS values |re| + |im|; mag[0] is the lowest frequency,
 *      mag[SPEC_BINS/2] the center frequency.
 */
void spectrum_mag(const int16_t *iq, int16_t *re, int16_t *im, uint16_t *mag);

/* ~16*log2(x), clamped to 0..255. */
uint8_t spec_log(uint32_t x);

/* Level in 0.1 dBFS for a spec_log() value. */
int16_t spec_log_to_ddb(uint8_t l);

#endif
