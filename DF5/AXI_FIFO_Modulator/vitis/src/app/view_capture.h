/*
 * view_capture.h -- screens drawn from the static capture: time plots over
 * the whole recording and the constellation.
 */
#ifndef VIEW_CAPTURE_H
#define VIEW_CAPTURE_H

#include "gfx/tft.h"
#include "app/capture.h"

/* I/Q pair of one stage: ch = CAP_IN_I, CAP_MIX_I or CAP_DEC_I (Q is ch + 1). */
void view_iq_pair(tft_t *tft, const capture_t *c, uint8_t ch, int32_t min_scale, const char *const *names);
void view_constellation(tft_t *tft, const capture_t *c);
void view_dphi(tft_t *tft, const capture_t *c);
void view_power(tft_t *tft, const capture_t *c);
void view_bit_decoder(tft_t *tft, const capture_t *c);
void view_decoder_timeline(tft_t *tft, const capture_t *c);

#endif
