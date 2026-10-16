/*
 * zoom.h -- visible window of a plot over n points: x1, x2, x4, x8 or x16, and
 * where it starts. Zooming keeps the window center; panning moves by 1/8 of
 * the window and stops at the ends.
 */
#ifndef ZOOM_H
#define ZOOM_H

#include <stdint.h>

#define ZOOM_LEVELS 5          /* x1, x2, x4, x8, x16 */

typedef struct {
    uint8_t level;             /* 0..ZOOM_LEVELS-1, factor = 1 << level */
    uint16_t off;              /* first visible point */
} zoom_t;

static inline uint16_t zoom_span(const zoom_t *z, uint16_t n) { return (uint16_t)(n >> z->level); }

/* Next zoom level (x16 -> x1), keeping the center. */
void zoom_cycle(zoom_t *z, uint16_t n);

/* Move the window: dir < 0 towards the start, dir > 0 towards the end. Returns 1 if it moved. */
int zoom_pan(zoom_t *z, uint16_t n, int dir);

#endif
