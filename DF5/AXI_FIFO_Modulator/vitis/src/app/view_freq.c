#include "app/view_freq.h"
#include "gfx/plot.h"

#define GRID_COLOR   TFT_RGB(0, 40, 140)
#define TRACE_COLOR  TFT_YELLOW
#define DB_DIVS      10          /* 10 dB per division, 0 .. -100 dBFS */

/* Spectrum-analyzer waterfall colors: 0..255 -> dark blue, blue, cyan, white. */
static uint16_t wf_color(uint8_t v)
{
    if (v < 96u)  return TFT_RGB(0, 0, 40u + (v * 215u) / 95u);
    if (v < 176u) return TFT_RGB(0, ((v - 96u) * 255u) / 80u, 255);
    return TFT_RGB(((v - 176u) * 255u) / 79u, 255, 255);
}

/* Color scale of the waterfall: from just above the mean level (noise) to the peak. */
static void wf_range(const cap_data_t *c, uint8_t *lo, uint8_t *hi)
{
    uint32_t sum = 0u;
    uint16_t r, b;

    *hi = 0u;
    for (r = 0u; r < CAP_WF_ROWS; r++)
        for (b = 0u; b < SPEC_BINS; b++) {
            sum += c->wf[r][b];
            if (c->wf[r][b] > *hi) *hi = c->wf[r][b];
        }
    *lo = (uint8_t)(sum / (CAP_WF_ROWS * SPEC_BINS) + 4u);
    if (*hi <= *lo) *hi = (uint8_t)(*lo + 1u);
}

static uint8_t wf_level(uint8_t l, uint8_t lo, uint8_t hi)
{
    return (l <= lo) ? 0u : (uint8_t)(((uint32_t)(l - lo) * 255u) / (hi - lo));
}

/* Frequency of bin b in kHz from the center (signed). */
static int32_t bin_khz(int32_t b)
{
    return ((b - SPEC_BINS / 2) * (int32_t)(CFG_SAMPLE_RATE_HZ / SPEC_FFT_N)) / 1000;
}

/* "-1125K" / "+250K" / "0" */
static void khz_label(char *buf, int32_t khz)
{
    char *p = buf;

    if (khz < 0) { *p++ = '-'; khz = -khz; }
    else if (khz > 0) *p++ = '+';
    p = plot_u32_to_str(p, (uint32_t)khz);
    if (khz != 0) { *p++ = 'K'; *p = '\0'; }
}

/* Visible start, center and end frequency under a plot. */
static void freq_axis(tft_t *tft, uint16_t x0, uint16_t w, uint16_t y, const zoom_t *z)
{
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    char buf[10];

    khz_label(buf, bin_khz(z->off));
    tft_draw_text(tft, x0, y, buf, TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, bin_khz(z->off + span / 2));
    tft_draw_text(tft, (uint16_t)(x0 + w / 2u - plot_text_w(buf) / 2u), y, buf, TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, bin_khz(z->off + span));
    tft_draw_text(tft, (uint16_t)(x0 + w - plot_text_w(buf)), y, buf, TFT_GRAY, TFT_BLACK, 1);
}

/* Waterfall rows [0, CAP_WF_ROWS) into the rectangle, visible bins only. */
static void draw_waterfall(tft_t *tft, const cap_data_t *c, const zoom_t *z,
                           uint16_t x0, uint16_t y0, uint16_t w, uint16_t h)
{
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    uint8_t lo, hi;
    uint16_t r, k;

    wf_range(c, &lo, &hi);
    for (r = 0u; r < CAP_WF_ROWS; r++) {
        uint16_t ya = (uint16_t)(y0 + (r * h) / CAP_WF_ROWS);
        uint16_t yb = (uint16_t)(y0 + ((r + 1u) * h) / CAP_WF_ROWS);

        if (yb <= ya) continue;
        for (k = 0u; k < span; k++) {
            uint16_t xa = (uint16_t)(x0 + (k * w) / span);
            uint16_t xb = (uint16_t)(x0 + ((k + 1u) * w) / span);

            if (xb > xa)
                tft_fill_rect(tft, xa, ya, (uint16_t)(xb - xa), (uint16_t)(yb - ya),
                              wf_color(wf_level(c->wf[r][z->off + k], lo, hi)));
        }
    }
}

/* y of a spec_log level on the dB grid (0 dBFS at the top, -100 at the bottom). */
static int16_t level_y(int32_t l, uint16_t y0, uint16_t h)
{
    int32_t ddb = ((l - SPEC_LOG_0DBFS) * 241) / 64;     /* 0.1 dB, see cap_level_ddb() */

    if (ddb > 0) ddb = 0;
    if (ddb < -DB_DIVS * 100) ddb = -DB_DIVS * 100;
    return (int16_t)(y0 + ((-ddb) * (int32_t)(h - 1u)) / (DB_DIVS * 100));
}

void view_fft(tft_t *tft, const cap_data_t *c, const zoom_t *z)
{
    uint16_t x0 = 6u, y0 = 28u;
    uint16_t w = (uint16_t)(tft->w - 12u - 26u);      /* 26 px for the dB labels */
    uint16_t h = (uint16_t)(tft->h - 47u);            /* 10 divisions, labels underneath */
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    uint16_t x, k, peak = 0u;
    int16_t prev = 0;
    char buf[24];
    char *p;
    int16_t ddb;

    /* grid and dB labels */
    for (k = 0u; k <= DB_DIVS; k++) {
        uint16_t y = (uint16_t)(y0 + (k * (h - 1u)) / DB_DIVS);
        tft_draw_hline(tft, x0, y, w, GRID_COLOR);
        buf[0] = '\0';
        if (k) { buf[0] = '-'; plot_u32_to_str(&buf[1], k * 10u); }
        else   { buf[0] = '0'; buf[1] = '\0'; }
        tft_draw_text(tft, (uint16_t)(x0 + w + 3u), (uint16_t)(y > y0 + 3u ? y - 3u : y0), buf, TFT_GRAY, TFT_BLACK, 1);
    }
    for (k = 0u; k <= 10u; k++)
        tft_draw_vline(tft, (uint16_t)(x0 + (k * (w - 1u)) / 10u), y0, h, GRID_COLOR);

    /* trace: levels interpolated between bins, joined column to column */
    for (x = 0u; x < w; x++) {
        uint32_t pos = ((uint32_t)x * (span - 1u) * 256u) / (w - 1u);
        uint16_t i = (uint16_t)(z->off + (pos >> 8));
        uint16_t fr = (uint16_t)(pos & 255u);
        int32_t l0 = c->fft[i];
        int32_t l1 = c->fft[(i + 1u < SPEC_BINS) ? i + 1u : i];
        int16_t y = level_y((l0 * (256 - fr) + l1 * fr) >> 8, y0, h);

        if (x == 0u) prev = y;
        plot_vline_clipped(tft, (uint16_t)(x0 + x), prev, y, y0, (uint16_t)(y0 + h - 1u), TRACE_COLOR);
        prev = y;
    }

    /* peak marker: square on the trace + readout */
    for (k = 1u; k < span; k++)
        if (c->fft[z->off + k] > c->fft[z->off + peak]) peak = k;
    tft_fill_rect(tft, (uint16_t)(x0 + (peak * (w - 1u)) / (span - 1u) - 2u),
                  (uint16_t)(level_y(c->fft[z->off + peak], y0, h) - 2), 5, 5, TFT_WHITE);
    p = buf;
    *p++ = 'P'; *p++ = 'K'; *p++ = ' ';
    khz_label(p, bin_khz(z->off + peak));
    while (*p) p++;
    *p++ = ' ';
    ddb = cap_level_ddb(c->fft[z->off + peak]);
    if (ddb < 0) { *p++ = '-'; ddb = (int16_t)-ddb; }
    p = plot_u32_to_str(p, (uint32_t)ddb / 10u);
    *p++ = '.';
    p = plot_u32_to_str(p, (uint32_t)ddb % 10u);
    *p++ = 'D'; *p++ = 'B'; *p++ = 'F'; *p++ = 'S'; *p = '\0';
    tft_draw_text(tft, (uint16_t)(x0 + 4u), (uint16_t)(y0 + 3u), buf, TFT_YELLOW, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(x0 + w - 52u), (uint16_t)(y0 + 3u), "MAX HOLD", TFT_GRAY, TFT_BLACK, 1);

    freq_axis(tft, x0, w, (uint16_t)(y0 + h + 2u), z);
}

void view_waterfall(tft_t *tft, const cap_data_t *c, const zoom_t *z)
{
    plot_box_t b = plot_area(tft);
    char buf[12];
    uint32_t t;
    uint8_t p;

    draw_waterfall(tft, c, z, b.x0, b.y0, b.w, b.h);
    freq_axis(tft, b.x0, b.w, (uint16_t)(b.y0 + b.h + 2u), z);

    /* time: capture start at the top, end at the bottom; packet starts on the right */
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u), (uint16_t)(b.y0 + 2u), "0MS", TFT_WHITE, TFT_BLACK, 1);
    t = (CFG_CAPTURE_SAMPLES * 10u) / (CFG_SAMPLE_RATE_HZ / 1000u);     /* 0.1 ms */
    {
        char *q = plot_u32_to_str(buf, t / 10u);
        *q++ = '.';
        q = plot_u32_to_str(q, t % 10u);
        *q++ = 'M'; *q++ = 'S'; *q = '\0';
    }
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u), (uint16_t)(b.y0 + b.h - 10u), buf, TFT_WHITE, TFT_BLACK, 1);

    for (p = 0u; p < c->npkt; p++) {
        uint16_t y = (uint16_t)(b.y0 + (c->pkt[p].start / 64u) * b.h / (CFG_CAPTURE_SAMPLES / 64u));
        char label[4] = { '<', 'P', (char)('1' + p), '\0' };
        tft_draw_text(tft, (uint16_t)(b.x0 + b.w - 20u), y, label, TFT_WHITE, TFT_BLACK, 1);
    }
}
