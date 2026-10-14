#include "app/view_spectrum.h"
#include "config.h"
#include "gfx/plot.h"

enum { LIVE_OFF = 0, LIVE_ARMED, LIVE_DRAW };

/* Color/height scale: 0 at the noise floor, 255 at +SPEC_SPAN steps (~36 dB). */
#define SPEC_SPAN 96u

/* Waterfall: oldest line at the top, each newer one lower and shifted right. */
enum { WF_SKEW = 2, WF_AMP = 64 };

/* Spectrogram: one pixel column per FFT, bh pixels per bin, labels on the right. */
typedef struct {
    uint16_t xs, ys, bh, gw, gh;
} spec_geom_t;

static spec_geom_t spec_geom(const tft_t *tft)
{
    plot_box_t b = plot_area(tft);
    spec_geom_t g;

    g.xs = (uint16_t)(b.x0 + 1u);
    g.ys = (uint16_t)(b.y0 + 1u);
    g.bh = (uint16_t)((b.h - 2u) / SPEC_BINS);
    g.gw = (uint16_t)(b.w - 2u - 38u);
    g.gh = (uint16_t)(g.bh * SPEC_BINS);
    return g;
}

static void wf_geom(const tft_t *tft, uint16_t *tw, uint16_t *step)
{
    plot_box_t b = plot_area(tft);
    *tw = (uint16_t)(b.w - 4u - WF_SKEW * (LIVE_WF_TRACES - 1u));
    *step = (uint16_t)((b.h - WF_AMP - 6u) / (LIVE_WF_TRACES - 1u));
}

static uint8_t spec_level(const live_spectrum_t *l, uint8_t x)
{
    uint32_t d;

    if (x <= l->lo) return 0u;
    d = ((uint32_t)(x - l->lo) * 255u) / SPEC_SPAN;
    return (uint8_t)(d > 255u ? 255u : d);
}

/* Half of the shown band in kHz, e.g. 562 for 4.5 MS/s. */
static uint32_t spec_half_khz(void)
{
    return (CFG_SAMPLE_RATE_HZ / SPEC_FFT_N) * (SPEC_BINS / 2u) / 1000u;
}

/* "-562K" / "+562K" */
static void khz_label(char *buf, char sign, uint32_t khz)
{
    char *p;

    buf[0] = sign;
    p = plot_u32_to_str(&buf[1], khz);
    *p++ = 'K';
    *p = '\0';
}

static void draw_spectro_frame(tft_t *tft)
{
    plot_box_t b = plot_area(tft);
    spec_geom_t g = spec_geom(tft);
    uint16_t xl = (uint16_t)(g.xs + g.gw + 4u);
    int32_t bin_hz = (int32_t)(CFG_SAMPLE_RATE_HZ / SPEC_FFT_N);
    int32_t ch_off = (int32_t)CFG_CHANNEL_FREQ_HZ - (int32_t)CFG_CENTER_FREQ_HZ;
    int32_t ch_bin = SPEC_BINS / 2 + (ch_off + (ch_off < 0 ? -bin_hz / 2 : bin_hz / 2)) / bin_hz;
    char buf[8];

    tft_draw_rect(tft, b.x0, b.y0, (uint16_t)(g.gw + 2u), (uint16_t)(g.gh + 2u), TFT_GRAY);

    khz_label(buf, '+', spec_half_khz());
    tft_draw_text(tft, xl, g.ys, buf, TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, xl, (uint16_t)(g.ys + (SPEC_BINS / 2u) * g.bh - 4u), "0", TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, '-', spec_half_khz());
    tft_draw_text(tft, xl, (uint16_t)(g.ys + g.gh - 8u), buf, TFT_GRAY, TFT_BLACK, 1);
    if (ch_bin >= 0 && ch_bin < SPEC_BINS)
        tft_draw_text(tft, xl, (uint16_t)(g.ys + (SPEC_BINS - 1u - (uint16_t)ch_bin) * g.bh + g.bh / 2u - 3u),
                      "<CH", TFT_WHITE, TFT_BLACK, 1);

    tft_draw_text(tft, b.x0, (uint16_t)(b.y0 + b.h + 2u), "TIME >", TFT_GRAY, TFT_BLACK, 1);
}

static void draw_waterfall_frame(tft_t *tft)
{
    plot_box_t b = plot_area(tft);
    uint16_t tw, step;
    char buf[8];

    wf_geom(tft, &tw, &step);
    tft_draw_rect(tft, b.x0, b.y0, b.w, b.h, TFT_GRAY);

    khz_label(buf, '-', spec_half_khz());
    tft_draw_text(tft, b.x0, (uint16_t)(b.y0 + b.h + 2u), buf, TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u + tw / 2u), (uint16_t)(b.y0 + b.h + 2u), "0", TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, '+', spec_half_khz());
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u + tw - plot_text_w(buf)), (uint16_t)(b.y0 + b.h + 2u), buf, TFT_GRAY, TFT_BLACK, 1);
}

static void draw_frame(live_spectrum_t *l)
{
    if (l->spectrogram) draw_spectro_frame(l->tft);
    else draw_waterfall_frame(l->tft);
}

static void message(live_spectrum_t *l, const char *msg, uint16_t color)
{
    plot_box_t b = plot_area(l->tft);
    tft_draw_text(l->tft, (uint16_t)(b.x0 + 8u), (uint16_t)(b.y0 + b.h / 2u - 4u), msg, color, TFT_BLACK, 1);
}

static void spectro_column(live_spectrum_t *l, const uint8_t *col)
{
    spec_geom_t g = spec_geom(l->tft);
    uint16_t x = (uint16_t)(g.xs + l->x);
    uint16_t r;

    tft_set_window(l->tft, x, g.ys, x, (uint16_t)(g.ys + g.gh - 1u));
    for (r = 0u; r < SPEC_BINS; r++)
        spi_tft_repeat16(l->tft->spi, plot_heat(spec_level(l, col[SPEC_BINS - 1u - r])), g.bh);

    if (l->x == LIVE_PRE)   /* burst start marker */
        tft_draw_vline(l->tft, x, (uint16_t)(g.ys + g.gh + 1u), 4u, TFT_WHITE);

    if (++l->x >= g.gw) l->state = LIVE_OFF;
}

static void waterfall_column(live_spectrum_t *l, const uint8_t *col)
{
    plot_box_t b = plot_area(l->tft);
    uint16_t tw, step, t, x, n;
    uint16_t x0, color;
    int16_t base, prev;

    for (n = 0u; n < SPEC_BINS; n++) l->wf_acc[n] += col[n];
    if (++l->x % LIVE_WF_EVERY != 0u) return;

    wf_geom(l->tft, &tw, &step);
    t = (uint16_t)(l->x / LIVE_WF_EVERY - 1u);
    x0 = (uint16_t)(b.x0 + 2u + t * WF_SKEW);
    base = (int16_t)(b.y0 + 3u + WF_AMP + t * step);
    color = plot_heat((uint8_t)(70u + (t * 185u) / (LIVE_WF_TRACES - 1u)));
    prev = base;

    for (x = 0u; x < tw; x++) {
        uint32_t pos = ((uint32_t)x * (SPEC_BINS - 1u) * 256u) / (tw - 1u);
        uint16_t i = (uint16_t)(pos >> 8);
        uint16_t fr = (uint16_t)(pos & 255u);
        uint16_t a0 = l->wf_acc[i];
        uint16_t a1 = l->wf_acc[(i + 1u < SPEC_BINS) ? i + 1u : i];
        uint8_t avg = (uint8_t)((((uint32_t)a0 * (256u - fr) + (uint32_t)a1 * fr) >> 8) / LIVE_WF_EVERY);
        int16_t y = (int16_t)(base - ((int32_t)spec_level(l, avg) * WF_AMP) / 255);

        /* Newer lines hide the older ones behind them: blank down to the baseline. */
        if (y < base)
            plot_vline_clipped(l->tft, (uint16_t)(x0 + x), (int16_t)(y + 1), base, (uint16_t)(b.y0 + 1u), (uint16_t)(b.y0 + b.h - 2u), TFT_BLACK);
        if (x > 0u)
            plot_vline_clipped(l->tft, (uint16_t)(x0 + x), prev, y, (uint16_t)(b.y0 + 1u), (uint16_t)(b.y0 + b.h - 2u), color);
        prev = y;
    }

    for (n = 0u; n < SPEC_BINS; n++) l->wf_acc[n] = 0u;
    if (t + 1u >= LIVE_WF_TRACES) l->state = LIVE_OFF;
}

static void column(live_spectrum_t *l, const uint8_t *col)
{
    if (l->spectrogram) spectro_column(l, col);
    else waterfall_column(l, col);
}

/* Burst found: noise floor from the pre-burst ring, then draw the ring (oldest first). */
static void start(live_spectrum_t *l)
{
    plot_box_t b = plot_area(l->tft);
    uint32_t sum = 0u;
    uint16_t c, n;

    for (c = 0u; c < LIVE_PRE; c++)
        for (n = 0u; n < SPEC_BINS; n++) sum += l->pre[c][n];
    l->lo = (uint8_t)(sum / (LIVE_PRE * SPEC_BINS) + 20u);   /* ~7.5 dB above mean noise */

    tft_fill_rect(l->tft, (uint16_t)(b.x0 + 1u), (uint16_t)(b.y0 + 1u), (uint16_t)(b.w - 2u), (uint16_t)(b.h - 2u), TFT_BLACK);
    draw_frame(l);

    l->state = LIVE_DRAW;
    for (c = 0u; c < LIVE_PRE && l->state == LIVE_DRAW; c++)
        column(l, l->pre[(l->pre_wr + c) % LIVE_PRE]);
}

void live_spectrum_arm(live_spectrum_t *l, tft_t *tft, int spectrogram, uint8_t skip)
{
    uint16_t n;

    l->tft = tft;
    l->state = LIVE_ARMED;
    l->spectrogram = (uint8_t)(spectrogram != 0);
    l->skip = skip;
    l->x = 0u;
    l->wait = 0u;
    l->pre_wr = 0u;
    for (n = 0u; n < SPEC_BINS; n++) l->wf_acc[n] = 0u;

    draw_frame(l);
    message(l, "WAITING FOR PACKET...", TFT_YELLOW);
}

void live_spectrum_stop(live_spectrum_t *l)
{
    l->state = LIVE_OFF;
}

int live_spectrum_active(const live_spectrum_t *l)
{
    return l->state != LIVE_OFF;
}

void live_spectrum_on_burst(live_spectrum_t *l)
{
    /* A burst before the pre-burst ring is full is not shown. */
    if (l->state != LIVE_ARMED || l->wait < LIVE_PRE) return;
    if (l->skip != 0u) l->skip--;
    else start(l);
}

void live_spectrum_feed(live_spectrum_t *l, const int16_t *iq, uint32_t n_samples)
{
    uint8_t col[SPEC_BINS];
    uint16_t n;

    if (l->state == LIVE_OFF || n_samples < SPEC_FFT_N) return;

    spectrum_column(iq, l->fft_re, l->fft_im, col);

    if (l->state == LIVE_DRAW) {
        column(l, col);
        return;
    }

    for (n = 0u; n < SPEC_BINS; n++) l->pre[l->pre_wr][n] = col[n];
    l->pre_wr = (uint8_t)((l->pre_wr + 1u) % LIVE_PRE);
    if (++l->wait > LIVE_TIMEOUT) {
        l->state = LIVE_OFF;
        message(l, "NO PACKET FOUND      ", TFT_RED);
    }
}
