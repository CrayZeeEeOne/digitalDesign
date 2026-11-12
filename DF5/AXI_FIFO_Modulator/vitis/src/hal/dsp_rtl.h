/*
 * dsp_rtl.h -- driver of dsp_top: the whole DSP in the PL (register map in
 * vivado/sources/rtl/dsp_regs.sv).
 *
 *   input       I/Q streamed from the SD card (sd_host -> S_AXIS), x 2^CFG_IN_SHIFT
 *   spectrum    FFT of every block over the whole band -> waterfall ring
 *   hop search  per block the level of the 15 channels: a packet on channel c
 *               retunes the demodulator to c and starts a capture (dsp_hop)
 *   demodulator after a 4096-sample delay line: NCO -> CIC -> discriminator ->
 *               burst detector -> bits -> sync, PN9, bytes, CRC16 (rtl_demod)
 *   capture     21.8 ms from just before each packet for RAW / BITS: I/Q
 *               columns, slicer bits of the packet
 *
 * Use: dsp_rtl_init() once; dsp_rtl_play_start() when the file starts; call
 * dsp_rtl_poll() all the time (it collects every decoded packet); when it
 * returns DSP_CAP_DONE, dsp_rtl_read_capture() and dsp_rtl_rearm().
 */
#ifndef DSP_RTL_H
#define DSP_RTL_H

#include <stdint.h>
#include "app/capture.h"

enum {
    DSP_CAP_IDLE = 0, DSP_CAP_WARMUP, DSP_CAP_WAIT, DSP_CAP_RECORD, DSP_CAP_DONE
};

#define DSP_LOG_N 8u           /* decoded packets kept for the screens */

typedef struct {
    uint32_t base;
    uint8_t ndec;              /* packets decoded during the current capture */
    cap_dec_t dec[CAP_PKTS];
    cap_dec_t log[DSP_LOG_N];  /* the last decoded packets, newest at log[(nlog - 1) % N] */
    uint32_t nlog;             /* packets decoded since dsp_rtl_play_start() */
    uint32_t spec_ctrl;        /* SPEC_CTRL as last written */
} dsp_rtl_t;

/* Checks both IDs and loads the configuration from config.h (demodulator,
   15 channels, spectrum, capture). 0 = ok, -1 = not found. */
int dsp_rtl_init(dsp_rtl_t *d, uint32_t base);

/* A file starts (or starts again): empty the delay line, demodulator from
   scratch, live spectrum, channel search on, capture armed for the next packet. */
void dsp_rtl_play_start(dsp_rtl_t *d);

/* Arm the capture for the next packet (after reading the previous one). */
void dsp_rtl_rearm(dsp_rtl_t *d);

/* Live spectrum on / off (off: the ring keeps the last rows -- pause). */
void dsp_rtl_live_spectrum(dsp_rtl_t *d, int on);

/* Freeze the ring (its rows stay as they are); every new row still goes to the
   last-row buffer, dsp_rtl_read_last(). */
void dsp_rtl_freeze(dsp_rtl_t *d, int on);
void dsp_rtl_read_last(const dsp_rtl_t *d, uint8_t *dst);

/* Rows written to the ring so far; row r is the r-th, the newest is rows - 1. */
uint32_t dsp_rtl_spec_rows(const dsp_rtl_t *d);

/* Row r of the ring (absolute index, kept for the last 256 rows). */
void dsp_rtl_read_row(const dsp_rtl_t *d, uint32_t row, uint8_t *dst);

/* Collects a decoded packet if one is ready (into d->log[], and into d->dec[]
   while recording); returns the capture state DSP_CAP_*. */
int dsp_rtl_poll(dsp_rtl_t *d);

/* Input samples accepted by the DSP since the start. */
uint32_t dsp_rtl_in_count(const dsp_rtl_t *d);

/* Copy the finished capture into c: columns, slicer bits, decoded packets. */
void dsp_rtl_read_capture(const dsp_rtl_t *d, cap_data_t *c);

/* Channel search: packets found / found without a packet in the demodulator. */
uint32_t dsp_rtl_hop_dets(const dsp_rtl_t *d);

#endif
