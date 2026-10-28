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

/* RF frequency of window bin b in kHz: the window is centred on the channel
   (config.h, SPEC_BIN0); bin offset from the LO = SPEC_CH_BINS + b - SPEC_BINS/2. */
static int32_t bin_khz(int32_t b)
{
    int32_t bins = SPEC_CH_BINS + b - SPEC_BINS / 2;
    return (int32_t)(CFG_CENTER_FREQ_HZ / 1000u)
         + (bins * (int32_t)CFG_SAMPLE_RATE_HZ / SPEC_FFT_N) / 1000;
}

/* "866.310M" */
static void khz_label(char *buf, int32_t khz)
{
    char *p = plot_u32_to_str(buf, (uint32_t)khz / 1000u);
    uint32_t f = (uint32_t)khz % 1000u;

    *p++ = '.';
    *p++ = (char)('0' + f / 100u);
    *p++ = (char)('0' + (f / 10u) % 10u);
    *p++ = (char)('0' + f % 10u);
    *p++ = 'M';
    *p = '\0';
}

/* Visible start, center and end frequency under a plot (padded: zoom changes them). */
static void freq_axis(tft_t *tft, uint16_t x0, uint16_t w, uint16_t y, const zoom_t *z)
{
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    char buf[10];

    plot_text_pad(tft, x0, y, "", (uint16_t)(w / 6u), TFT_GRAY);
    khz_label(buf, bin_khz(z->off));
    tft_draw_text(tft, x0, y, buf, TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, bin_khz(z->off + span / 2));
    tft_draw_text(tft, (uint16_t)(x0 + w / 2u - plot_text_w(buf) / 2u), y, buf, TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, bin_khz(z->off + span));
    tft_draw_text(tft, (uint16_t)(x0 + w - plot_text_w(buf)), y, buf, TFT_GRAY, TFT_BLACK, 1);
}

/* y of a spec_log level on the dB grid (0 dBFS at the top, -100 at the bottom), from the box top. */
static int16_t level_y(int32_t l, uint16_t h)
{
    int32_t ddb = ((l - SPEC_LOG_0DBFS) * 241) / 64;     /* 0.1 dB, see cap_level_ddb() */

    if (ddb > 0) ddb = 0;
    if (ddb < -DB_DIVS * 100) ddb = -DB_DIVS * 100;
    return (int16_t)(((-ddb) * (int32_t)(h - 1u)) / (DB_DIVS * 100));
}

void view_fft(tft_t *tft, const uint8_t *fft, const char *tag, const zoom_t *z, int full)
{
    uint16_t x0 = 6u, y0 = 28u;
    uint16_t w = (uint16_t)(tft->w - 12u - 26u);      /* 26 px for the dB labels */
    uint16_t h = (uint16_t)(tft->h - 47u);            /* 10 divisions, labels underneath */
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    uint8_t *t_lo = plot_scratch.fft.t_lo, *t_hi = plot_scratch.fft.t_hi;
    uint16_t *line = plot_scratch.fft.line;
    uint16_t x, y, k, peak = 0u, gx = 0u, gy = 0u;
    int16_t prev = 0;
    char buf[28];
    char *p;
    int16_t ddb;

    if (w > PLOT_MAX_W) w = PLOT_MAX_W;
    if (full) {                                      /* dB labels: fixed */
        for (k = 0u; k <= DB_DIVS; k++) {
            uint16_t yy = (uint16_t)(y0 + (k * (h - 1u)) / DB_DIVS);
            if (k) { buf[0] = '-'; plot_u32_to_str(&buf[1], k * 10u); }
            else   { buf[0] = '0'; buf[1] = '\0'; }
            tft_draw_text(tft, (uint16_t)(x0 + w + 3u), (uint16_t)(yy > y0 + 3u ? yy - 3u : y0), buf, TFT_GRAY, TFT_BLACK, 1);
        }
    }

    /* trace: levels interpolated between bins, joined column to column -> a span per column */
    for (x = 0u; x < w; x++) {
        uint32_t pos = ((uint32_t)x * (span - 1u) * 256u) / (w - 1u);
        uint16_t i = (uint16_t)(z->off + (pos >> 8));
        uint16_t fr = (uint16_t)(pos & 255u);
        int32_t l0 = fft[i];
        int32_t l1 = fft[(i + 1u < SPEC_BINS) ? i + 1u : i];
        int16_t yy = level_y((l0 * (256 - fr) + l1 * fr) >> 8, h);

        if (x == 0u) prev = yy;
        t_lo[x] = (uint8_t)((prev < yy) ? prev : yy);
        t_hi[x] = (uint8_t)((prev < yy) ? yy : prev);
        prev = yy;
    }

    /* grid lines: 11 columns and 11 rows, positions computed once (no division per pixel) */
    {
        uint16_t gcol[11], grow[11];
        for (k = 0u; k <= 10u; k++) {
            gcol[k] = (uint16_t)((k * (w - 1u)) / 10u);
            grow[k] = (uint16_t)((k * (h - 1u)) / DB_DIVS);
        }

        /* one window, row by row: trace over grid over background (no flicker) */
        tft_set_window(tft, x0, y0, (uint16_t)(x0 + w - 1u), (uint16_t)(y0 + h - 1u));
        for (y = 0u; y < h; y++) {
            int grid_row = (gy <= 10u && y == grow[gy]);
            uint16_t bg = grid_row ? GRID_COLOR : TFT_BLACK;

            if (grid_row) gy++;
            gx = 0u;
            for (x = 0u; x < w; x++) {
                uint16_t c = bg;
                if (gx <= 10u && x == gcol[gx]) { c = GRID_COLOR; gx++; }
                if (y >= t_lo[x] && y <= t_hi[x]) c = TRACE_COLOR;
                line[x] = c;
            }
            spi_tft_write16(tft->spi, line, w);
            if (tft->idle && (y & 15u) == 0u) tft->idle();
        }
    }

    /* peak marker: square on the trace + readout */
    for (k = 1u; k < span; k++)
        if (fft[z->off + k] > fft[z->off + peak]) peak = k;
    tft_fill_rect(tft, (uint16_t)(x0 + (peak * (w - 1u)) / (span - 1u) - 2u),
                  (uint16_t)(y0 + level_y(fft[z->off + peak], h) - 2), 5, 5, TFT_WHITE);
    p = buf;
    *p++ = 'P'; *p++ = 'K'; *p++ = ' ';
    khz_label(p, bin_khz(z->off + peak));
    while (*p) p++;
    *p++ = ' ';
    ddb = cap_level_ddb(fft[z->off + peak]);
    if (ddb < 0) { *p++ = '-'; ddb = (int16_t)-ddb; }
    p = plot_u32_to_str(p, (uint32_t)ddb / 10u);
    *p++ = '.';
    p = plot_u32_to_str(p, (uint32_t)ddb % 10u);
    *p++ = 'D'; *p++ = 'B'; *p++ = 'F'; *p++ = 'S'; *p = '\0';
    tft_draw_text(tft, (uint16_t)(x0 + 4u), (uint16_t)(y0 + 3u), buf, TFT_YELLOW, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(x0 + w - 4u - plot_text_w(tag)), (uint16_t)(y0 + 3u), tag, TFT_GRAY, TFT_BLACK, 1);

    freq_axis(tft, x0, w, (uint16_t)(y0 + h + 2u), z);
}

/* "72.8MS" / "-713MS" from 0.1 ms */
static void ms10_label(char *buf, uint32_t t, int minus)
{
    char *q = buf;

    if (minus) *q++ = '-';
    q = plot_u32_to_str(q, t / 10u);
    if (t < 1000u) { *q++ = '.'; q = plot_u32_to_str(q, t % 10u); }
    *q++ = 'M'; *q++ = 'S'; *q = '\0';
}

void view_waterfall(tft_t *tft, const wf_src_t *s, const cap_data_t *c, const zoom_t *z, int full)
{
    uint16_t *lut = plot_scratch.wf.lut;
    uint16_t *line = plot_scratch.wf.line;
    uint8_t *xbin = plot_scratch.wf.xbin;
    plot_box_t b = plot_area(tft);
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    uint32_t sum = 0u, n = 0u;
    uint8_t lo, hi = 0u;
    uint16_t x, y, r, last = 0xFFFFu;
    char buf[12];

    (void)full;
    if (b.w > PLOT_MAX_W) b.w = PLOT_MAX_W;
    if (s->nrows == 0u) return;

    /* color scale: from just above the mean level (noise) to the peak of the visible rows */
    for (r = 0u; r < s->nrows; r++) {
        const uint8_t *row = s->row(s->ctx, r);
        for (x = 0u; x < SPEC_BINS; x++) {
            sum += row[x];
            if (row[x] > hi) hi = row[x];
        }
        n += SPEC_BINS;
    }
    lo = (uint8_t)(sum / n + 4u);
    if (hi <= lo) hi = (uint8_t)(lo + 1u);
    for (x = 0u; x < 256u; x++)
        lut[x] = wf_color((x <= lo) ? 0u : (uint8_t)(((uint32_t)(x - lo) * 255u) / (hi - lo)));
    for (x = 0u; x < b.w; x++) xbin[x] = (uint8_t)(z->off + ((uint32_t)x * span) / b.w);

    /* one window, line by line */
    tft_set_window(tft, b.x0, b.y0, (uint16_t)(b.x0 + b.w - 1u), (uint16_t)(b.y0 + b.h - 1u));
    for (y = 0u; y < b.h; y++) {
        r = (uint16_t)(((uint32_t)y * s->nrows) / b.h);
        if (r != last) {
            const uint8_t *row = s->row(s->ctx, r);
            for (x = 0u; x < b.w; x++) line[x] = lut[row[xbin[x]]];
            last = r;
        }
        spi_tft_write16(tft->spi, line, b.w);
        if (tft->idle && (y & 15u) == 0u) tft->idle();
    }

    freq_axis(tft, b.x0, b.w, (uint16_t)(b.y0 + b.h + 2u), z);

    /* time: top and bottom row */
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u), (uint16_t)(b.y0 + 2u), s->live ? "NOW" : "0MS", TFT_WHITE, TFT_BLACK, 1);
    ms10_label(buf, s->span_ms10, s->live);
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u), (uint16_t)(b.y0 + b.h - 10u), buf, TFT_WHITE, TFT_BLACK, 1);

    /* packet starts on the right (capture only) */
    if (c && !s->live) {
        uint8_t p;
        for (p = 0u; p < c->npkt; p++) {
            uint16_t yy = (uint16_t)(b.y0 + (c->pkt[p].start / 64u) * b.h / (CFG_CAPTURE_SAMPLES / 64u));
            char label[4] = { '<', 'P', (char)('1' + p), '\0' };
            tft_draw_text(tft, (uint16_t)(b.x0 + b.w - 20u), yy, label, TFT_WHITE, TFT_BLACK, 1);
        }
    }
}
