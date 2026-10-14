/*
 * src_synth.h -- synthetic test signal: 2-FSK packets at the channel frequency
 * (CFG_CHANNEL_FREQ_HZ, -250 kHz from the center), noise in the gaps.
 *
 *   packet: SRC_PKT_SYMS symbols (SRC_PREAMBLE of 0101..., then pseudo-random bits)
 *   gap:    SRC_GAP_SYMS symbols of noise only
 *   level:  amplitude SRC_AMP, uniform noise +-128 on I and Q
 */
#ifndef SRC_SYNTH_H
#define SRC_SYNTH_H

#include <stdint.h>
#include "source/iq_source.h"

#define SRC_CARRIER_INC  (-3641)   /* -250 kHz at 4.5 MS/s, 16-bit phase */
#define SRC_DEV_INC      728       /* +-50 kHz deviation */
#define SRC_AMP          3000
#define SRC_PKT_SYMS     192u
#define SRC_GAP_SYMS     128u
#define SRC_PREAMBLE     32u

typedef struct {
    iq_source_t base;
    uint32_t phase;            /* carrier phase, low 16 bits used */
    uint32_t sym_phase;        /* symbol clock accumulator */
    uint32_t sym_count;        /* symbols since start */
    uint32_t lfsr;             /* noise generator state */
} src_synth_t;

void src_synth_init(src_synth_t *s);

#endif
