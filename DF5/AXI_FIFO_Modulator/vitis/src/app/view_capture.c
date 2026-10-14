#include "app/view_capture.h"
#include "config.h"
#include "gfx/plot.h"
#include "dsp/burst_detect.h"
#include "dsp/dsp_math.h"

/* Series over a cap_col_t field: lo/hi are the field in col[0]. */
static plot_series_t col_series(const void *lo, const void *hi, uint8_t is_signed)
{
    plot_series_t s;

    s.lo = lo;
    s.hi = hi;
    s.stride = (uint16_t)sizeof(cap_col_t);
    s.count = CAP_COLS;
    s.is_signed = is_signed;
    s.map = 0;
    return s;
}

static void flag_steps(tft_t *tft, const plot_box_t *b, const capture_t *c, uint8_t mask, uint8_t level, uint16_t color)
{
    plot_flag_steps(tft, b, &c->col[0].flags, (uint16_t)sizeof(cap_col_t), CAP_COLS, mask, level, color);
}

/* "0" under the left edge, capture length in ms under the right edge. */
static void time_axis(tft_t *tft, const plot_box_t *b)
{
    uint32_t us10 = (CFG_CAPTURE_SAMPLES * 10u) / (CFG_SAMPLE_RATE_HZ / 1000u);  /* 0.1 ms units */
    char buf[12];
    char *p = plot_u32_to_str(buf, us10 / 10u);
    uint16_t y = (uint16_t)(b->y0 + b->h + 2u);

    *p++ = '.';
    p = plot_u32_to_str(p, us10 % 10u);
    *p++ = 'M'; *p++ = 'S'; *p = '\0';

    tft_draw_text(tft, b->x0, y, "0", TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(b->x0 + b->w - plot_text_w(buf)), y, buf, TFT_GRAY, TFT_BLACK, 1);
}

void view_iq_pair(tft_t *tft, const capture_t *c, uint8_t ch, int32_t min_scale, const char *const *names)
{
    static const uint16_t colors[2] = { TFT_CYAN, TFT_YELLOW };
    plot_box_t b = plot_area(tft);
    const cap_col_t *c0 = &c->col[0];
    plot_series_t si = col_series(&c0->lo[ch], &c0->hi[ch], 1u);
    plot_series_t sq = col_series(&c0->lo[ch + 1u], &c0->hi[ch + 1u], 1u);
    int32_t scale = plot_series_scale(&si, min_scale);
    int32_t s2 = plot_series_scale(&sq, min_scale);

    if (s2 > scale) scale = s2;

    plot_axis_box(tft, b.x0, b.y0, b.w, b.h);
    plot_series_draw(tft, &b, &si, scale, TFT_CYAN);
    plot_series_draw(tft, &b, &sq, scale, TFT_YELLOW);
    plot_legend(tft, &b, names, colors, 2u);
    time_axis(tft, &b);
}

void view_constellation(tft_t *tft, const capture_t *c)
{
    uint16_t side = (uint16_t)(tft->h - 40u);
    uint16_t x0 = (uint16_t)((tft->w - side) / 2u);
    uint16_t y0 = 30u;
    int32_t scale = 64;
    uint16_t i;
    int16_t cx, cy;

    for (i = 0u; i < c->cons_n; i++) {
        if (abs32(c->cons_i[i]) > scale) scale = abs32(c->cons_i[i]);
        if (abs32(c->cons_q[i]) > scale) scale = abs32(c->cons_q[i]);
    }
    scale += scale >> 3;

    plot_axis_box(tft, x0, y0, side, side);
    cx = (int16_t)(x0 + side / 2u);
    cy = (int16_t)(y0 + side / 2u);

    for (i = 0u; i < c->cons_n; i++) {
        int16_t x = (int16_t)(cx + (c->cons_i[i] * (int32_t)(side / 2u - 3u)) / scale);
        int16_t y = (int16_t)(cy - (c->cons_q[i] * (int32_t)(side / 2u - 3u)) / scale);
        tft_fill_rect(tft, (uint16_t)(x - 1), (uint16_t)(y - 1), 3, 3, TFT_CYAN);
    }
}

void view_dphi(tft_t *tft, const capture_t *c)
{
    static const char *const names[1] = { "DPHI" };
    static const uint16_t colors[1] = { TFT_MAGENTA };
    plot_box_t b = plot_area(tft);
    const cap_col_t *c0 = &c->col[0];
    plot_series_t s = col_series(&c0->dphi_lo, &c0->dphi_hi, 1u);

    plot_axis_box(tft, b.x0, b.y0, b.w, b.h);
    plot_series_draw(tft, &b, &s, plot_series_scale(&s, 700), TFT_MAGENTA);
    plot_legend(tft, &b, names, colors, 1u);
    time_axis(tft, &b);
}

void view_power(tft_t *tft, const capture_t *c)
{
    static const char *const names[4] = { "PAVG", "NOISE", "THR", "BURST" };
    static const uint16_t colors[4] = { TFT_GREEN, TFT_WHITE, TFT_YELLOW, TFT_RED };
    plot_box_t b = plot_area(tft);
    const cap_col_t *c0 = &c->col[0];
    plot_series_t pavg = col_series(&c0->pavg, &c0->pavg, 0u);
    plot_series_t noise = col_series(&c0->noise, &c0->noise, 0u);
    plot_series_t thr = noise;
    int32_t scale, s_thr;

    thr.map = burst_threshold;
    scale = plot_series_scale(&pavg, 64);
    s_thr = plot_series_scale(&thr, 64);
    if (s_thr > scale) scale = s_thr;

    tft_draw_rect(tft, b.x0, b.y0, b.w, b.h, TFT_GRAY);
    flag_steps(tft, &b, c, DEMOD_F_BURST, 15u, TFT_RED);
    plot_series_draw(tft, &b, &noise, scale, TFT_WHITE);
    plot_series_draw(tft, &b, &thr, scale, TFT_YELLOW);
    plot_series_draw(tft, &b, &pavg, scale, TFT_GREEN);
    plot_legend(tft, &b, names, colors, 4u);
    time_axis(tft, &b);
}

void view_bit_decoder(tft_t *tft, const capture_t *c)
{
    static const char *const names[6] = { "DPHI", "AFC", "DEV", "SYNC", "PRE", "PKT" };
    static const uint16_t colors[6] = { TFT_MAGENTA, TFT_CYAN, TFT_WHITE, TFT_RED, TFT_YELLOW, TFT_GREEN };
    plot_box_t b = plot_area(tft);
    const cap_col_t *c0 = &c->col[0];
    plot_series_t dphi = col_series(&c0->dphi_lo, &c0->dphi_hi, 1u);
    plot_series_t favg = col_series(&c0->favg, &c0->favg, 1u);
    plot_series_t dev = col_series(&c0->dev, &c0->dev, 1u);
    int32_t scale = plot_series_scale(&dphi, 700);

    plot_axis_box(tft, b.x0, b.y0, b.w, b.h);
    plot_series_draw(tft, &b, &dphi, scale, TFT_MAGENTA);
    plot_series_draw(tft, &b, &favg, scale, TFT_CYAN);
    plot_series_draw(tft, &b, &dev, scale, TFT_WHITE);
    flag_steps(tft, &b, c, DEMOD_F_SYNC, 14u, TFT_RED);
    flag_steps(tft, &b, c, DEMOD_F_PRE, 13u, TFT_YELLOW);
    flag_steps(tft, &b, c, DEMOD_F_PKT, 12u, TFT_GREEN);
    plot_legend(tft, &b, names, colors, 6u);
    time_axis(tft, &b);
}

void view_decoder_timeline(tft_t *tft, const capture_t *c)
{
    static const char *const names[4] = { "SYNC", "PRE", "PKT", "BUR" };
    static const uint8_t masks[4] = { DEMOD_F_SYNC, DEMOD_F_PRE, DEMOD_F_PKT, DEMOD_F_BURST };
    static const uint16_t colors[4] = { TFT_RED, TFT_YELLOW, TFT_GREEN, TFT_CYAN };
    plot_box_t b = plot_area(tft);
    uint16_t lane = b.h / 4u;
    uint16_t x;
    uint8_t l;

    tft_draw_rect(tft, b.x0, b.y0, b.w, b.h, TFT_GRAY);
    for (l = 1u; l < 4u; l++)
        tft_draw_hline(tft, b.x0, (uint16_t)(b.y0 + l * lane), b.w, TFT_GRAY);

    for (x = 0u; x < b.w; x++) {
        uint8_t f = c->col[plot_x_to_idx(&b, x, CAP_COLS)].flags;
        uint16_t xx = (uint16_t)(b.x0 + x);

        if (f & DEMOD_F_RES) {
            tft_draw_vline(tft, xx, (uint16_t)(b.y0 + 1u), (uint16_t)(b.h - 2u), TFT_WHITE);
            continue;
        }
        for (l = 0u; l < 4u; l++)
            if (f & masks[l])
                tft_draw_vline(tft, xx, (uint16_t)(b.y0 + l * lane + 2u), (uint16_t)(lane - 4u), colors[l]);
    }

    for (l = 0u; l < 4u; l++)
        tft_draw_text(tft, (uint16_t)(b.x0 + 4u), (uint16_t)(b.y0 + l * lane + 2u), names[l], colors[l], TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(b.x0 + b.w - 24u), (uint16_t)(b.y0 + 2u), "RES", TFT_WHITE, TFT_BLACK, 1);
    time_axis(tft, &b);
}
