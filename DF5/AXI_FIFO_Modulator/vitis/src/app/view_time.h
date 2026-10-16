/*
 * view_time.h -- screens over the time of the capture: the raw I/Q signal and
 * the decoded bits. The zoom window counts in capture columns (CAP_RAW_COLS).
 */
#ifndef VIEW_TIME_H
#define VIEW_TIME_H

#include "gfx/tft.h"
#include "app/capture.h"
#include "app/zoom.h"

#define VIEW_TIME_POINTS CAP_RAW_COLS

void view_raw(tft_t *tft, const capture_t *c, const zoom_t *z);
void view_bits(tft_t *tft, const capture_t *c, const zoom_t *z);

#endif
