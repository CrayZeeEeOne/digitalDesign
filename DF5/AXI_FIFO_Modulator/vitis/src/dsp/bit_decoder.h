/*
 * bit_decoder.h -- what happens to the instantaneous frequency after the
 * burst detector: AFC (mean frequency), deviation, and decoder state flags.
 *
 * The flags are a placeholder: SYNC/PRE/PKT turn on by burst age (8/16/28
 * decimated samples), not by a real sync-word search as in
 * demod_bit_decoder.sv.
 */
#ifndef BIT_DECODER_H
#define BIT_DECODER_H

#include <stdint.h>

/* Decoder state flags. */
enum {
    DEMOD_F_BURST = 1u << 0,
    DEMOD_F_SYNC  = 1u << 1,
    DEMOD_F_PRE   = 1u << 2,
    DEMOD_F_PKT   = 1u << 3,
    DEMOD_F_RES   = 1u << 4    /* packet just ended (result ready) */
};

typedef struct {
    int16_t favg;              /* AFC: smoothed dphi (1/8) */
    int16_t dev;               /* smoothed |dphi - favg| (1/16) */
    uint8_t pkt_active;
    uint32_t burst_start;      /* dec_count when the current burst started */
} bit_decoder_t;

/* One decimated sample. dec_count: its index; burst_rise: burst started on it. */
uint8_t bit_decoder_step(bit_decoder_t *b, int32_t dphi, int burst, int burst_rise, uint32_t dec_count);

#endif
