#include "gfx/plot.h"

plot_scratch_t plot_scratch;

static int32_t iabs(int32_t x) { return (x < 0) ? -x : x; }

char *plot_u32_to_str(char *p, uint32_t x)
{
    char tmp[10];
    int n = 0;

    do { tmp[n++] = (char)('0' + x % 10u); x /= 10u; } while (x != 0u);
    while (n > 0) *p++ = tmp[--n];
    *p = '\0';
    return p;
}

uint16_t plot_text_w(const char *s)
{
    uint16_t n = 0u;
    while (*s++) n++;
    return (uint16_t)(n * 6u);
}

plot_box_t plot_area(const tft_t *tft)
{
    plot_box_t b;
    b.x0 = 6u;
    b.y0 = 28u;
    b.w = (uint16_t)(tft->w - 12u);
    b.h = (uint16_t)(tft->h - 44u);
    return b;
}

void plot_axis_box(tft_t *tft, uint16_t x, uint16_t y, uint16_t w, uint16_t h)
{
    tft_draw_rect(tft, x, y, w, h, TFT_GRAY);
    tft_draw_hline(tft, (uint16_t)(x + 2u), (uint16_t)(y + h / 2u), (uint16_t)(w - 4u), TFT_GRAY);
    tft_draw_vline(tft, (uint16_t)(x + w / 2u), (uint16_t)(y + 2u), (uint16_t)(h - 4u), TFT_GRAY);
}

void plot_legend(tft_t *tft, const plot_box_t *b, const char *const *names, const uint16_t *colors, uint8_t n)
{
    uint16_t x = (uint16_t)(b->x0 + 4u);
    uint8_t i;

    for (i = 0u; i < n; i++) {
        tft_draw_text(tft, x, (uint16_t)(b->y0 + 3u), names[i], colors[i], TFT_BLACK, 1);
        x = (uint16_t)(x + plot_text_w(names[i]) + 6u);
    }
}

void plot_vline_clipped(tft_t *tft, uint16_t x, int16_t y1, int16_t y2, uint16_t ymin, uint16_t ymax, uint16_t color)
{
    int16_t lo = y1;
    int16_t hi = y2;

    if (lo > hi) { int16_t tt = lo; lo = hi; hi = tt; }
    if (hi < (int16_t)ymin || lo > (int16_t)ymax) return;

    if (lo < (int16_t)ymin) lo = (int16_t)ymin;
    if (hi > (int16_t)ymax) hi = (int16_t)ymax;

    tft_draw_vline(tft, x, (uint16_t)lo, (uint16_t)(hi - lo + 1), color);
}

uint16_t plot_x_to_idx(const plot_box_t *b, uint16_t x, uint16_t count)
{
    return (uint16_t)(((uint32_t)x * count) / b->w);
}

static int32_t series_val(const plot_series_t *s, const void *field0, uint16_t i)
{
    const uint8_t *p = (const uint8_t *)field0 + (uint32_t)i * s->stride;

    if (s->is_signed) return s->is_byte ? *(const int8_t *)p : *(const int16_t *)p;
    if (s->map) return (int32_t)s->map(*(const uint16_t *)p);
    return *(const uint16_t *)p;
}

int32_t plot_series_scale(const plot_series_t *s, int32_t m)
{
    uint16_t i;

    for (i = 0u; i < s->count; i++) {
        int32_t a = iabs(series_val(s, s->lo, i));
        int32_t b = iabs(series_val(s, s->hi, i));
        if (a > m) m = a;
        if (b > m) m = b;
    }
    return m + (m >> 3);
}

static int16_t value_y(const plot_box_t *b, int32_t val, int32_t scale, uint8_t is_signed)
{
    if (!is_signed)
        return (int16_t)(b->y0 + b->h - 3 - (val * (int32_t)(b->h - 6u)) / scale);
    return (int16_t)(b->y0 + b->h / 2u - (val * (int32_t)(b->h / 2u - 3u)) / scale);
}

void plot_series_draw(tft_t *tft, const plot_box_t *b, const plot_series_t *s, int32_t scale, uint16_t color)
{
    uint16_t x;
    int16_t pt = 0, pb = 0;

    for (x = 0u; x < b->w; x++) {
        uint16_t i = plot_x_to_idx(b, x, s->count);
        int16_t t = value_y(b, series_val(s, s->hi, i), scale, s->is_signed);
        int16_t bo = value_y(b, series_val(s, s->lo, i), scale, s->is_signed);

        if (x == 0u) { pt = t; pb = bo; }
        plot_vline_clipped(tft, (uint16_t)(b->x0 + x), (t < pb) ? t : pb, (bo > pt) ? bo : pt,
                           (uint16_t)(b->y0 + 1u), (uint16_t)(b->y0 + b->h - 2u), color);
        pt = t;
        pb = bo;
    }
}

void plot_col_fill(plot_col_t *c, uint16_t h, uint16_t color)
{
    uint16_t y;

    c->h = (h > PLOT_COL_MAX) ? PLOT_COL_MAX : h;
    for (y = 0u; y < c->h; y++) c->px[y] = color;
}

void plot_col_span(plot_col_t *c, int16_t y1, int16_t y2, uint16_t color)
{
    int16_t y;

    if (y1 > y2) { y = y1; y1 = y2; y2 = y; }
    if (y1 < 0) y1 = 0;
    if (y2 >= (int16_t)c->h) y2 = (int16_t)(c->h - 1u);
    for (y = y1; y <= y2; y++) c->px[y] = color;
}

void plot_col_send(tft_t *tft, uint16_t x, uint16_t y0, const plot_col_t *c)
{
    tft_push_rect(tft, x, y0, 1u, c->h, c->px);
}

void plot_text_pad(tft_t *tft, uint16_t x, uint16_t y, const char *s, uint16_t n, uint16_t fg)
{
    char buf[60];
    uint16_t i = 0u;

    if (n >= sizeof(buf)) n = sizeof(buf) - 1u;
    while (i < n && s[i]) { buf[i] = s[i]; i++; }
    while (i < n) buf[i++] = ' ';
    buf[n] = '\0';
    tft_draw_text(tft, x, y, buf, fg, TFT_BLACK, 1);
}
