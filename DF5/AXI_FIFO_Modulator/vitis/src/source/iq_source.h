/*
 * iq_source.h -- where I/Q samples come from.
 *
 * Every source (synthetic test signal, file on the SD card, RTL capture)
 * embeds iq_source_t as its first member, so the rest of the firmware works
 * with any of them through the same call.
 */
#ifndef IQ_SOURCE_H
#define IQ_SOURCE_H

#include <stdint.h>

typedef struct iq_source iq_source_t;

struct iq_source {
    /* Fill iq with n interleaved samples (I0, Q0, I1, Q1, ...). */
    void (*read)(iq_source_t *s, int16_t *iq, uint32_t n);
};

static inline void iq_source_read(iq_source_t *s, int16_t *iq, uint32_t n)
{
    s->read(s, iq, n);
}

#endif
