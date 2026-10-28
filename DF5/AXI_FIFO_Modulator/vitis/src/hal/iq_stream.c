#include "hal/iq_stream.h"
#include "xil_io.h"

#define IQS_CTRL    0x00u    /* [0] enable [1] flush [2] clear stats */
#define IQS_DATA    0x08u
#define IQS_LEVEL   0x0Cu
#define IQS_POPPED  0x14u
#define IQS_ID      0x1Cu

#define IQS_ID_VAL  0x49510001u

static inline uint32_t rd(const iq_stream_t *s, uint32_t r) { return Xil_In32(s->base + r); }
static inline void wr(const iq_stream_t *s, uint32_t r, uint32_t v) { Xil_Out32(s->base + r, v); }

int iq_stream_init(iq_stream_t *s, uint32_t base)
{
    s->base = base;
    if (rd(s, IQS_ID) != IQS_ID_VAL) return -1;
    iq_stream_flush(s);
    return 0;
}

void iq_stream_flush(iq_stream_t *s)
{
    wr(s, IQS_CTRL, 0x7u);                       /* enable + flush + clear stats */
}

uint32_t iq_stream_space(const iq_stream_t *s)
{
    uint32_t level = rd(s, IQS_LEVEL);
    return (level >= IQ_STREAM_DEPTH) ? 0u : IQ_STREAM_DEPTH - level;
}

void iq_stream_push(iq_stream_t *s, const uint32_t *iq, uint32_t n)
{
    while (n--) wr(s, IQS_DATA, *iq++);
}

uint32_t iq_stream_popped(const iq_stream_t *s)
{
    return rd(s, IQS_POPPED);
}
