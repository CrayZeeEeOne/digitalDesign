/*
 * dsp_rtl.h -- driver of dsp_top: the whole DSP in the PL (register map in
 * vivado/sources/rtl/dsp_regs.sv).
 *
 *   source      S_AXIS (I/Q replay through iq_stream) or the built-in test
 *               generator (GFSK packets in noise, the sim.iq format)
 *   demodulator NCO -> CIC -> discriminator -> burst detector -> bits -> sync,
 *               bytes, CRC (rtl_demod, configured from config.h)
 *   capture     one recording for the screens: I/Q columns, slicer bits of
 *               two packets, waterfall and max-hold spectrum
 *
 * Typical use: dsp_rtl_init(), dsp_rtl_set_source(), dsp_rtl_start(); call
 * dsp_rtl_poll() until it returns DSP_CAP_DONE (it collects the decoded
 * packets meanwhile), then dsp_rtl_read_capture().
 */
#ifndef DSP_RTL_H
#define DSP_RTL_H

#include <stdint.h>
#include "app/capture.h"

typedef enum {
    DSP_SRC_STREAM = 0,        /* S_AXIS: samples written to iq_stream */
    DSP_SRC_GEN    = 1         /* built-in test generator */
} dsp_src_t;

enum {
    DSP_CAP_IDLE = 0, DSP_CAP_WARMUP, DSP_CAP_WAIT, DSP_CAP_RECORD, DSP_CAP_DONE
};

typedef struct {
    uint32_t base;
} dsp_rtl_t;

/* Checks both IDs and loads the configuration from config.h. 0 = ok, -1 = not found. */
int dsp_rtl_init(dsp_rtl_t *d, uint32_t base);

void dsp_rtl_set_source(dsp_rtl_t *d, dsp_src_t src);

/* Clean demodulator state, enable it, arm a capture. nowait = record right after
   the warm-up instead of waiting for the end of a packet (replay of a file). */
void dsp_rtl_start(dsp_rtl_t *d, int nowait, cap_data_t *c);

/* Collects a decoded packet if one is ready (into c->dec[] while recording);
   returns the capture state DSP_CAP_*. */
int dsp_rtl_poll(dsp_rtl_t *d, cap_data_t *c);

/* Samples recorded so far (0..CFG_CAPTURE_SAMPLES). */
uint32_t dsp_rtl_capture_pos(const dsp_rtl_t *d);

/* Copy the finished capture (columns, bits, spectra) into c; dec[] is kept. */
void dsp_rtl_read_capture(const dsp_rtl_t *d, cap_data_t *c);

/* Packets sent by the generator / decoded with CRC OK since the start. */
uint32_t dsp_rtl_gen_packets(const dsp_rtl_t *d);
uint32_t dsp_rtl_crc_ok_count(const dsp_rtl_t *d);

#endif
