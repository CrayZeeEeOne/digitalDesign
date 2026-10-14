/* dsp_math.h -- small fixed-point helpers shared by the DSP blocks. */
#ifndef DSP_MATH_H
#define DSP_MATH_H

#include <stdint.h>

/* Q15 sine of a 16-bit phase (2^16 = 2*pi), quarter-wave table lookup. */
int16_t sin_q15(uint16_t phase);

static inline int32_t abs32(int32_t x) { return (x < 0) ? -x : x; }

static inline uint16_t clamp_u16(uint32_t x) { return (uint16_t)(x > 65535u ? 65535u : x); }

#endif
