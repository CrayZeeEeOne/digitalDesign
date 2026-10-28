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
    uint8_t ndec;              /* packets decoded during the current recording */
    cap_dec_t dec[CAP_PKTS];
} dsp_rtl_t;

/* Checks both IDs and loads the configuration from config.h. 0 = ok, -1 = not found. */
int dsp_rtl_init(dsp_rtl_t *d, uint32_t base);

void dsp_rtl_set_source(dsp_rtl_t *d, dsp_src_t src);

/* One capture: clean demodulator state, enable it, arm. nowait = record right
   after the warm-up instead of waiting for the end of a packet (replay of a
   file). Spectrum of the recorded blocks only (rows 0..39). */
void dsp_rtl_start(dsp_rtl_t *d, int nowait);

/*
 * Live: generator in real time, demodulator running, spectrum of every block
 * into the ring (one row per 2^CFG_LIVE_WF_SHIFT blocks), capture armed without
 * trigger wait. After each finished capture: dsp_rtl_read_capture(), then
 * dsp_rtl_rearm() -- the spectrum is not disturbed by it.
 */
void dsp_rtl_live_start(dsp_rtl_t *d);
void dsp_rtl_rearm(dsp_rtl_t *d);

/* Live spectrum on / off (off: the ring keeps the last rows -- pause). */
void dsp_rtl_live_spectrum(dsp_rtl_t *d, int on);

/* Rows written to the ring so far; row r is the r-th, the newest is rows - 1. */
uint32_t dsp_rtl_spec_rows(const dsp_rtl_t *d);

/* Row r of the ring (absolute index, kept for the last 256 rows). */
void dsp_rtl_read_row(const dsp_rtl_t *d, uint32_t row, uint8_t *dst);

/* Collects a decoded packet if one is ready (into d->dec[] while recording);
   returns the capture state DSP_CAP_*. */
int dsp_rtl_poll(dsp_rtl_t *d);

/* Samples recorded so far (0..CFG_CAPTURE_SAMPLES). */
uint32_t dsp_rtl_capture_pos(const dsp_rtl_t *d);

/* Copy the finished capture into c: columns, bits, decoded packets, and with
   spectra = 1 the 40 waterfall rows and their max hold (capture mode only). */
void dsp_rtl_read_capture(const dsp_rtl_t *d, cap_data_t *c, int spectra);

/* Packets sent by the generator / decoded with CRC OK since the start. */
uint32_t dsp_rtl_gen_packets(const dsp_rtl_t *d);
uint32_t dsp_rtl_crc_ok_count(const dsp_rtl_t *d);

#endif
