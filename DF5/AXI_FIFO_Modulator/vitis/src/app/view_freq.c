#include "app/view_freq.h"
#include "gfx/plot.h"

#define GRID_COLOR   TFT_RGB(0, 40, 140)
#define TRACE_COLOR  TFT_YELLOW
#define DB_DIVS      10          /* 10 dB per division, 0 .. -100 dBFS */

/* Waterfall colors: 0 (noise) = blue background; the signal goes from red (just
   above the noise) through orange to yellow (the strongest), with a short blend
   from the blue to the red at the bottom.
   This panel shows the waterfall with red and blue exchanged (seen on the board:
   a red background, blue packets), so the palette is sent with R and B swapped.
   The PC emulator (tools/host_sim, HOST_SIM) shows the colors as they are sent. */
#ifdef HOST_SIM
#define WF_RGB(r, g, b) TFT_RGB((r), (g), (b))
#else
#define WF_RGB(r, g, b) TFT_RGB((b), (g), (r))
#endif

static uint16_t wf_color(uint8_t v)
{
    if (v == 0u)  return WF_RGB(0, 0, 120);
    if (v < 32u)  return WF_RGB((v * 255u) / 32u, 0, 120u - (v * 120u) / 32u);
    return WF_RGB(255, ((v - 32u) * 255u) / 223u, 0);
}

/* RF frequency of point b in kHz: the points cover the whole band, point b is
   FFT bins 2b and 2b+1 from -Fs/2 (config.h, SPEC_BIN0), centre (2b + 0.5 - 128)
   bins from the LO; a bin is Fs/256. */
static int32_t bin_khz(int32_t b)
{
    return (int32_t)(CFG_CENTER_FREQ_HZ / 1000u)
         + ((4 * b + 1 - 2 * SPEC_FFT_N / 2) * (int32_t)(CFG_SAMPLE_RATE_HZ / 1000u)) / (2 * SPEC_FFT_N);
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

/* "866.31M": axis labels, rounded to 10 kHz (5 of them fit under a plot) */
static void khz_label_axis(char *buf, int32_t khz)
{
    char *p;

    khz_label(buf, ((khz + 5) / 10) * 10);
    for (p = buf; *p != 'M'; p++)
        ;
    p[-1] = 'M';
    *p = '\0';
}

/* Frequency at 5 points under a plot: edges, quarters, centre (padded: zoom changes them). */
static void freq_axis(tft_t *tft, uint16_t x0, uint16_t w, uint16_t y, const zoom_t *z)
{
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    char buf[10];
    uint16_t k;

    plot_text_pad(tft, x0, y, "", (uint16_t)(w / 6u), TFT_GRAY);
    for (k = 0u; k <= 4u; k++) {
        uint16_t tw, x;

        khz_label_axis(buf, bin_khz(z->off + (span * k) / 4u));
        tw = plot_text_w(buf);
        x = (uint16_t)(x0 + (w * k) / 4u);
        x = (k == 0u) ? x0 : (k == 4u) ? (uint16_t)(x0 + w - tw) : (uint16_t)(x - tw / 2u);
        tft_draw_text(tft, x, y, buf, TFT_GRAY, TFT_BLACK, 1);
    }
}

/* y of a spec_log level on the dB grid (0 dBFS at the top, -100 at the bottom), from the box top. */
static int16_t level_y(int32_t l, uint16_t h)
{
    int32_t ddb = ((l - SPEC_LOG_0DBFS) * 241) / 64;     /* 0.1 dB, see cap_level_ddb() */

    if (ddb > 0) ddb = 0;
    if (ddb < -DB_DIVS * 100) ddb = -DB_DIVS * 100;
    return (int16_t)(((-ddb) * (int32_t)(h - 1u)) / (DB_DIVS * 100));
}

/* The FFT plot in a box (x0, y0, w, h); dB labels right of it, the frequency
   axis under it if axis. */
static void fft_in(tft_t *tft, uint16_t x0, uint16_t y0, uint16_t w, uint16_t h,
                   const uint8_t *fft, const char *tag, const zoom_t *z, int full, int axis)
{
    uint16_t lstep = (h < 150u) ? 2u : 1u;            /* small box: a label every 20 dB */
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
        for (k = 0u; k <= DB_DIVS; k += lstep) {
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

    if (axis) freq_axis(tft, x0, w, (uint16_t)(y0 + h + 2u), z);
}

void view_fft(tft_t *tft, const uint8_t *fft, const char *tag, const zoom_t *z, int full)
{
    /* 26 px right for the dB labels; 10 divisions, the frequency labels underneath */
    fft_in(tft, 6u, 28u, (uint16_t)(tft->w - 12u - 26u), (uint16_t)(tft->h - 47u), fft, tag, z, full, 1);
}

/* Time axis right of the waterfall, in seconds from the top row (live: seconds
   ago, 0 = now): a label every step, the step chosen for <= 9 labels. */
static void time_axis_s(tft_t *tft, const plot_box_t *b, uint32_t span_ms10)
{
    static const uint16_t steps[] = { 100u, 200u, 500u, 1000u, 2000u, 5000u, 10000u, 20000u };  /* 0.1 ms */
    uint16_t x = (uint16_t)(b->x0 + b->w + 2u);
    uint32_t step = steps[0], t;
    uint16_t k, y;
    char buf[8];

    for (k = 0u; k < sizeof(steps) / sizeof(steps[0]); k++) {
        step = steps[k];
        if (span_ms10 / step <= 8u) break;
    }
    tft_fill_rect(tft, x, b->y0, (uint16_t)(tft->w - 1u - x), b->h, TFT_BLACK);
    tft_draw_text(tft, (uint16_t)(x + 8u), (uint16_t)(b->y0 + b->h + 2u), "S", TFT_GRAY, TFT_BLACK, 1);
    if (span_ms10 == 0u) return;
    for (t = 0u; t <= span_ms10; t += step) {
        uint32_t cs = t / 100u;                  /* 0.01 s */
        char *q;

        y = (uint16_t)(b->y0 + (t * (b->h - 1u)) / span_ms10);
        q = plot_u32_to_str(buf, cs / 100u);
        *q++ = '.';
        *q++ = (char)('0' + (cs / 10u) % 10u);
        if (step < 1000u) *q++ = (char)('0' + cs % 10u);     /* steps below 0.1 s */
        *q = '\0';
        if (y + 4u > b->y0 + b->h) y = (uint16_t)(b->y0 + b->h - 4u);
        tft_draw_text(tft, (uint16_t)(x + 2u), (uint16_t)((y >= b->y0 + 3u) ? y - 3u : b->y0), buf,
                      TFT_GRAY, TFT_BLACK, 1);
    }
}

/* The waterfall in box b; the time in s right of it, the frequency axis under it. */
static void wf_in(tft_t *tft, plot_box_t b, const wf_src_t *s, const cap_data_t *c, const zoom_t *z)
{
    uint16_t *lut = plot_scratch.wf.lut;
    uint16_t *line = plot_scratch.wf.line;
    uint8_t *xbin = plot_scratch.wf.xbin;
    uint16_t span = zoom_span(z, VIEW_FREQ_POINTS);
    uint8_t *cm = plot_scratch.wf.cm;
    uint16_t colsum[SPEC_BINS];
    uint32_t n = 0u;
    uint8_t lo, hi = 0u;
    uint16_t x, y, r, last = 0xFFFFu, cur_y;

    if (b.w > PLOT_MAX_W) b.w = PLOT_MAX_W;
    if (s->nrows == 0u) return;

    /* background: the mean level of each frequency over the rows (rows not recorded
       yet -- all zero -- do not count). It is subtracted, so steady carriers (the
       LO, interferers) sink into the blue and the packets stand out; the colors
       go from just above that background to the strongest point. */
    for (x = 0u; x < SPEC_BINS; x++) colsum[x] = 0u;
    for (r = 0u; r < s->nrows; r++) {
        const uint8_t *row = s->row(s->ctx, r);
        uint32_t rs = 0u;
        for (x = 0u; x < SPEC_BINS; x++) rs += row[x];
        if (!rs) continue;
        for (x = 0u; x < SPEC_BINS; x++) colsum[x] = (uint16_t)(colsum[x] + row[x]);
        n++;
    }
    for (x = 0u; x < SPEC_BINS; x++) cm[x] = (uint8_t)(n ? colsum[x] / n : 0u);
    for (r = 0u; r < s->nrows; r++) {
        const uint8_t *row = s->row(s->ctx, r);
        for (x = 0u; x < SPEC_BINS; x++)
            if (row[x] > cm[x] && (uint8_t)(row[x] - cm[x]) > hi) hi = (uint8_t)(row[x] - cm[x]);
    }
    lo = 4u;
    if (hi <= lo) hi = (uint8_t)(lo + 1u);
    for (x = 0u; x < 256u; x++)
        lut[x] = wf_color((x <= lo) ? 0u : (x >= hi) ? 255u : (uint8_t)(((uint32_t)(x - lo) * 255u) / (hi - lo)));
    for (x = 0u; x < b.w; x++) xbin[x] = (uint8_t)(z->off + ((uint32_t)x * span) / b.w);

    /* one window, line by line; the cursor row -- a white line */
    cur_y = (s->cursor < s->nrows) ? (uint16_t)(((uint32_t)s->cursor * b.h) / s->nrows) : 0xFFFFu;
    tft_set_window(tft, b.x0, b.y0, (uint16_t)(b.x0 + b.w - 1u), (uint16_t)(b.y0 + b.h - 1u));
    for (y = 0u; y < b.h; y++) {
        r = (uint16_t)(((uint32_t)y * s->nrows) / b.h);
        if (r != last) {
            const uint8_t *row = s->row(s->ctx, r);
            for (x = 0u; x < b.w; x++) {
                uint8_t k = xbin[x];
                line[x] = lut[(row[k] > cm[k]) ? (uint8_t)(row[k] - cm[k]) : 0u];
            }
            last = r;
        }
        if (y == cur_y) spi_tft_repeat16(tft->spi, TFT_WHITE, b.w);
        else            spi_tft_write16(tft->spi, line, b.w);
        if (tft->idle && (y & 15u) == 0u) tft->idle();
    }

    freq_axis(tft, b.x0, b.w, (uint16_t)(b.y0 + b.h + 2u), z);
    time_axis_s(tft, &b, s->span_ms10);
    if (s->live) tft_draw_text(tft, (uint16_t)(b.x0 + 2u), (uint16_t)(b.y0 + 2u), "NOW", TFT_WHITE, TFT_BLACK, 1);

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

void view_waterfall(tft_t *tft, const wf_src_t *s, const cap_data_t *c, const zoom_t *z, int full)
{
    plot_box_t b = plot_area(tft);

    if (s->frozen && !full) return;                  /* the picture of the file is on the screen */
    b.w = (uint16_t)(b.w - 26u);                      /* 26 px right of the plot: time in s */
    wf_in(tft, b, s, c, z);
}

void view_fft_wf(tft_t *tft, const uint8_t *fft, const char *tag, const wf_src_t *s, const zoom_t *z, int full)
{
    plot_box_t b = plot_area(tft);
    uint16_t fh = 84u;                                /* the FFT on top, the waterfall below */

    b.w = (uint16_t)(b.w - 26u);
    fft_in(tft, b.x0, b.y0, b.w, fh, fft, tag, z, full, 0);
    if (s->frozen && !full) return;
    b.y0 = (uint16_t)(b.y0 + fh + 4u);
    b.h = (uint16_t)(b.h - fh - 4u);
    wf_in(tft, b, s, 0, z);
}
