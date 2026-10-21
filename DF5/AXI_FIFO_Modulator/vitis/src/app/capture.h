/*
 * capture.h -- one fixed recording for the static screens (the data only).
 *
 * On the board the RTL fills it (dsp_top: dsp_capture + dsp_spectrum, read out
 * by hal/dsp_rtl.c); on the PC the C model (tools/host_sim/model/dsp/
 * capture_model.c) computes the same thing from software I/Q. The capture starts in a gap (right after a packet
 * ends) and covers CFG_CAPTURE_SAMPLES input samples:
 *   raw[]    min/max of input I and Q in CAP_RAW_COLS columns, in steps of
 *            2^CAP_RAW_SHIFT (int8, saturated); raw samples are not kept
 *   pkt[]    slicer decisions of up to CAP_PKTS packets, from the burst start
 *   dec[]    the same packets decoded by the demodulator (after sync, with CRC)
 *   fft[]    spectrum of the capture: max hold over the waterfall rows (spec_log levels)
 *   wf[][]   waterfall: CAP_WF_ROWS spectra, row 0 = start of the capture
 * Nothing here draws.
 */
#ifndef CAPTURE_H
#define CAPTURE_H

#include <stdint.h>
#include "config.h"

#define CAP_RAW_COLS  384
#define CAP_WF_ROWS   40
#define CAP_PKTS      2
#define CAP_PKT_BITS  512
#define CAP_DEC_BYTES 64
#define CAP_RAW_SHIFT 6        /* raw[] step: 64 ADC units, range +-8128 */

typedef struct {
    int8_t i_lo, i_hi, q_lo, q_hi;
} cap_raw_t;

typedef struct {
    uint32_t start, end;       /* burst start / end, samples from the capture start */
    uint32_t first_bit;        /* sample of the first bit decision */
    uint16_t nbits;
    uint8_t bits[CAP_PKT_BITS / 8];    /* first bit = MSB of bits[0] */
} cap_pkt_t;

typedef struct {
    uint8_t valid;             /* the demodulator found the sync word */
    uint8_t crc_ok;
    uint8_t nbytes;            /* bytes after sync, CRC included */
    uint8_t bytes[CAP_DEC_BYTES];
} cap_dec_t;

typedef struct {
    cap_raw_t raw[CAP_RAW_COLS];
    cap_pkt_t pkt[CAP_PKTS];
    uint8_t npkt;              /* packets recorded */
    cap_dec_t dec[CAP_PKTS];
    uint8_t ndec;              /* packets decoded */
    uint8_t fft[SPEC_BINS];
    uint8_t wf[CAP_WF_ROWS][SPEC_BINS];
} cap_data_t;

/* Bit k of a packet (0/1). */
static inline uint8_t cap_pkt_bit(const cap_pkt_t *p, uint16_t k)
{
    return (uint8_t)((p->bits[k >> 3] >> (7u - (k & 7u))) & 1u);
}

/* Level in 0.1 dBFS for a spectrum level (~16*log2: 20*log10(2)/16 dB per step). */
static inline int16_t cap_level_ddb(uint8_t l)
{
    return (int16_t)(((int32_t)l - SPEC_LOG_0DBFS) * 241 / 64);
}

#endif
