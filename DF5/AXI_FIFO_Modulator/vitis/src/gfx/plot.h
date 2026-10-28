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

/*
 * One pixel column of a plot, built in RAM and sent in one window: the old
 * picture is overwritten in place, so live redraws do not flicker.
 * y is relative to the top of the column; everything outside [0, h) is clipped.
 */
#define PLOT_COL_MAX 240

typedef struct {
    uint16_t h;
    uint16_t px[PLOT_COL_MAX];
} plot_col_t;

void plot_col_fill(plot_col_t *c, uint16_t h, uint16_t color);
void plot_col_span(plot_col_t *c, int16_t y1, int16_t y2, uint16_t color);
static inline void plot_col_dot(plot_col_t *c, int16_t y, uint16_t color)
{
    if (y >= 0 && y < (int16_t)c->h) c->px[y] = color;
}
void plot_col_send(tft_t *tft, uint16_t x, uint16_t y0, const plot_col_t *c);

/*
 * Work memory of the screens, shared: only one screen draws at a time
 * (BRAM is tight). PLOT_MAX_W: widest plot area.
 */
#define PLOT_MAX_W 320

typedef union {
    plot_col_t col;                                  /* RAW, BITS */
    struct { uint8_t t_lo[PLOT_MAX_W], t_hi[PLOT_MAX_W]; uint16_t line[PLOT_MAX_W]; } fft;
    struct { uint16_t lut[256]; uint16_t line[PLOT_MAX_W]; uint8_t xbin[PLOT_MAX_W]; } wf;
} plot_scratch_t;

extern plot_scratch_t plot_scratch;

/* Text padded with spaces to n characters (erases a longer old label). */
void plot_text_pad(tft_t *tft, uint16_t x, uint16_t y, const char *s, uint16_t n, uint16_t fg);

#endif
