/*
 * view_time.h -- screens over the time of the capture: the raw I/Q signal and
 * the decoded bits. The zoom window counts in capture columns (CAP_RAW_COLS).
 * Drawn column by column over the old picture (no clear): fit for live redraws.
 */
#ifndef VIEW_TIME_H
#define VIEW_TIME_H

#include "gfx/tft.h"
#include "app/capture.h"
#include "app/zoom.h"
#include "app/rx_stats.h"

#define VIEW_TIME_POINTS CAP_RAW_COLS

/* full: the screen was just cleared (unused: everything is redrawn every time). */
void view_raw(tft_t *tft, const cap_data_t *c, const zoom_t *z, int full);
/* st: receive statistics shown under the packets (NULL: none). */
void view_bits(tft_t *tft, const cap_data_t *c, const zoom_t *z, int full, const rx_stats_t *st);

#endif
