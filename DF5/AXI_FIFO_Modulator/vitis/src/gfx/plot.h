/*
 * plot.h -- plotting primitives on top of the TFT driver: plot area, axes,
 * legend, min/max envelopes, step lines, heat-map colors, text helpers.
 * Knows nothing about what is being plotted.
 */
#ifndef PLOT_H
#define PLOT_H

#include <stdint.h>
#include "gfx/tft.h"

typedef struct {
    uint16_t x0, y0, w, h;
} plot_box_t;

/*
 * A series of points stored in an array of structs: lo/hi point at the field
 * in element 0, stride is the struct size. lo == hi gives a plain line.
 */
typedef struct {
    const void *lo;
    const void *hi;
    uint16_t stride;
    uint16_t count;
    uint8_t is_signed;          /* 1: signed, zero in the middle; 0: uint16, zero at the bottom */
    uint8_t is_byte;            /* signed values stored as int8 instead of int16 */
    uint32_t (*map)(uint32_t);  /* optional transform of uint16 values, NULL = none */
} plot_series_t;

/*-------------------------------------------------------------- text ----*/
char *plot_u32_to_str(char *p, uint32_t x);    /* returns the end ('\0') */
uint16_t plot_text_w(const char *s);           /* width at scale 1 */

/*------------------------------------------------------------ layout ----*/
/* Main plot area: below the title, 12 px left at the bottom for axis labels. */
plot_box_t plot_area(const tft_t *tft);

void plot_axis_box(tft_t *tft, uint16_t x, uint16_t y, uint16_t w, uint16_t h);
void plot_legend(tft_t *tft, const plot_box_t *b, const char *const *names, const uint16_t *colors, uint8_t n);
void plot_vline_clipped(tft_t *tft, uint16_t x, int16_t y1, int16_t y2, uint16_t ymin, uint16_t ymax, uint16_t color);

/* Index of the point drawn at pixel column x (0..b->w-1). */
uint16_t plot_x_to_idx(const plot_box_t *b, uint16_t x, uint16_t count);

/*------------------------------------------------------------ series ----*/
/* Largest |value| over the series (at least m), plus 1/8 headroom. */
int32_t plot_series_scale(const plot_series_t *s, int32_t m);

/* Min/max envelope over the whole box width, joined to the previous column. */
void plot_series_draw(tft_t *tft, const plot_box_t *b, const plot_series_t *s, int32_t scale, uint16_t color);

#endif
