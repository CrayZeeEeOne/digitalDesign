/*
 * iq_stream.h -- driver of iq_stream_top: a 1024-word FIFO the CPU fills with
 * I/Q pairs; its AXI-Stream output feeds dsp_top (source S_AXIS).
 * Register map: vivado/sources/rtl/iq_stream_regs.sv.
 */
#ifndef IQ_STREAM_H
#define IQ_STREAM_H

#include <stdint.h>

#define IQ_STREAM_DEPTH 1024u

typedef struct {
    uint32_t base;
} iq_stream_t;

/* Check the ID, flush, output enabled. 0 = ok, -1 = core not found. */
int iq_stream_init(iq_stream_t *s, uint32_t base);

/* Empty the FIFO and clear the counters. */
void iq_stream_flush(iq_stream_t *s);

/* Free words in the FIFO. */
uint32_t iq_stream_space(const iq_stream_t *s);

/* Push n pairs {Q[31:16], I[15:0]}; the caller checks iq_stream_space() first. */
void iq_stream_push(iq_stream_t *s, const uint32_t *iq, uint32_t n);

/* Pairs taken by the DSP since the last flush. */
uint32_t iq_stream_popped(const iq_stream_t *s);

#endif
