#include "graph_viewer.h"
#include "dsp_tables.h"

#define DECIM 16
#define BURST_HANG 16   /* decimated samples below threshold before burst ends */
#define CONS_EVERY (GV_CAPTURE_SAMPLES / DECIM / GV_CONST_POINTS)

typedef struct {
    uint16_t x0, y0, w, h;
} box_t;

static int32_t abs32(int32_t x) { return (x < 0) ? -x : x; }

static uint16_t clamp_u16(uint32_t x) { return (uint16_t)(x > 65535u ? 65535u : x); }

static int16_t sin_q15(uint16_t phase)
{
    uint16_t idx = (phase >> 6) & 1023u;
    uint16_t q = idx >> 8;
    uint16_t o = idx & 255u;

    switch (q) {
    case 0: return  dsp_sin_q15[o];
    case 1: return  dsp_sin_q15[256u - o];
    case 2: return -dsp_sin_q15[o];
    default: return -dsp_sin_q15[256u - o];
    }
}

/*------------------------------------------------------------ spectrum ----*/

/* In-place radix-2 DIT FFT, GV_FFT_N points, scaled by 1/2 per stage. */
static void fft_q15(int16_t *re, int16_t *im)
{
    uint16_t i, j, k, len;

    for (i = 1u, j = 0u; i < GV_FFT_N; i++) {
        uint16_t bit = GV_FFT_N >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            int16_t t;
            t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }

    for (len = 2u; len <= GV_FFT_N; len <<= 1) {
        uint16_t half = len >> 1;
        uint16_t dph = (uint16_t)(65536u / len);

        for (i = 0u; i < GV_FFT_N; i += len) {
            for (k = 0u; k < half; k++) {
                uint16_t ph = (uint16_t)(k * dph);
                int32_t wr = sin_q15((uint16_t)(ph + 16384u));
                int32_t wi = -sin_q15(ph);
                uint16_t a = (uint16_t)(i + k);
                uint16_t b = (uint16_t)(a + half);
                int32_t tr = (re[b] * wr - im[b] * wi) >> 15;
                int32_t ti = (re[b] * wi + im[b] * wr) >> 15;

                re[b] = (int16_t)((re[a] - tr) >> 1);
                im[b] = (int16_t)((im[a] - ti) >> 1);
                re[a] = (int16_t)((re[a] + tr) >> 1);
                im[a] = (int16_t)((im[a] + ti) >> 1);
            }
        }
    }
}

/* ~16*log2(x) (about 0.38 dB per step), clamped to 0..255. */
static uint8_t log2_u8(uint32_t x)
{
    uint32_t n = 0u;
    uint32_t frac;

    if (x == 0u) return 0u;
    while ((x >> n) > 1u) n++;
    frac = (n >= 4u) ? (x >> (n - 4u)) & 15u : (x << (4u - n)) & 15u;
    n = n * 16u + frac;
    return (uint8_t)(n > 255u ? 255u : n);
}

enum { LIVE_OFF = 0, LIVE_ARMED, LIVE_DRAW };

static void live_column(graph_viewer_t *v, const uint8_t *col);
static void live_start(graph_viewer_t *v);
static void live_timeout(graph_viewer_t *v);

/* One FFT of the block start -> one spectrum column (log magnitude of the central bins). */
static void spectrum_column(graph_viewer_t *v, const int16_t *iq, uint32_t n_samples)
{
    int16_t *re = v->fft_re;
    int16_t *im = v->fft_im;
    uint8_t col[GV_SPEC_BINS];
    uint16_t n;

    if (v->live == LIVE_OFF || n_samples < GV_FFT_N) return;

    for (n = 0u; n < GV_FFT_N; n++) {
        int32_t w = dsp_hann_q15[n * (DSP_FFT_N / GV_FFT_N) + (DSP_FFT_N / GV_FFT_N / 2)];
        re[n] = (int16_t)(((int32_t)iq[2u * n] * w) >> 15);
        im[n] = (int16_t)(((int32_t)iq[2u * n + 1u] * w) >> 15);
    }

    fft_q15(re, im);

    for (n = 0u; n < GV_SPEC_BINS; n++) {
        uint16_t k = (uint16_t)((n - GV_SPEC_BINS / 2u) & (GV_FFT_N - 1u));
        col[n] = log2_u8((uint32_t)(abs32(re[k]) + abs32(im[k])));
    }

    if (v->live == LIVE_DRAW) {
        live_column(v, col);
        return;
    }

    for (n = 0u; n < GV_SPEC_BINS; n++) v->spec_pre[v->spec_wr][n] = col[n];
    v->spec_wr = (uint8_t)((v->spec_wr + 1u) % GV_SPEC_PRE);
    if (++v->live_wait > GV_LIVE_TIMEOUT) live_timeout(v);
}

/*------------------------------------------------------------ datapath ----*/

static uint32_t threshold_of(uint32_t noise)
{
    uint32_t th = noise + (noise >> 1);
    if (th < 700u) th = 700u;
    if (th > 4095u) th = 4095u;
    return th;
}

static uint8_t decoder_flags(graph_viewer_t *v)
{
    uint8_t flags = 0u;
    uint8_t was_pkt = v->pkt_active;

    v->pkt_active = 0u;

    if (v->burst) {
        uint32_t age = v->dec_count - v->burst_start;
        flags |= GV_F_BURST;
        if (age > 8u)  flags |= GV_F_SYNC;
        if (age > 16u) flags |= GV_F_PRE;
        if (age > 28u) { v->pkt_active = 1u; flags |= GV_F_PKT; }
    }

    if (was_pkt && !v->pkt_active) flags |= GV_F_RES;
    return flags;
}

static void env_put(int16_t *lo, int16_t *hi, int16_t x)
{
    if (x < *lo) *lo = x;
    if (x > *hi) *hi = x;
}

void graph_viewer_init(graph_viewer_t *v, const viewer_cfg_t *cfg)
{
    int i, ch;

    for (i = 0; i < (int)sizeof(*v); i++) ((uint8_t *)v)[i] = 0;

    v->cfg = *cfg;
    v->mode = VIEW_INPUT_IQ;

    v->nco_inc = (uint16_t)((((uint32_t)65536u) * (cfg->center_freq_hz - cfg->channel_freq_hz) / cfg->sample_rate_hz) & 0xFFFFu);
    if (v->nco_inc == 0u) v->nco_inc = 911u;

    v->noise = 600u;
    v->pavg = 600u;

    for (i = 0; i < GV_COLS; i++) {
        for (ch = 0; ch < GV_CH_COUNT; ch++) {
            v->col[i].lo[ch] = 32767;
            v->col[i].hi[ch] = -32768;
        }
        v->col[i].dphi_lo = 32767;
        v->col[i].dphi_hi = -32768;
    }
    v->col_edge = GV_CAPTURE_SAMPLES / GV_COLS;
}

void graph_viewer_set_mode(graph_viewer_t *v, view_mode_t mode)
{
    if (mode >= VIEW_COUNT) mode = VIEW_INPUT_IQ;
    v->mode = mode;
}

void graph_viewer_next(graph_viewer_t *v)
{
    v->mode = (view_mode_t)((v->mode + 1u) % VIEW_COUNT);
}

void graph_viewer_prev(graph_viewer_t *v)
{
    v->mode = (view_mode_t)((v->mode + VIEW_COUNT - 1u) % VIEW_COUNT);
}

int graph_viewer_done(const graph_viewer_t *v)
{
    return v->done;
}

int graph_viewer_busy(const graph_viewer_t *v)
{
    return !v->done || v->live != LIVE_OFF;
}

void graph_viewer_process_block(graph_viewer_t *v, const int16_t *iq, uint32_t n_samples)
{
    uint32_t k;

    if (!graph_viewer_busy(v)) return;

    for (k = 0; k < n_samples; k++) {
        int16_t i0 = iq[2u * k + 0u];
        int16_t q0 = iq[2u * k + 1u];
        int16_t lo_i, lo_q;
        int16_t mi, mq;
        uint32_t pwr;
        int32_t dphi;
        gv_col_t *c = 0;

        if (!v->done && v->sample_count >= GV_WARMUP_SAMPLES) {
            uint32_t pos = v->sample_count - GV_WARMUP_SAMPLES;

            if (pos >= GV_CAPTURE_SAMPLES) {
                v->done = 1u;
            } else {
                while (pos >= v->col_edge) {
                    v->col_idx++;
                    v->col_edge = ((uint32_t)(v->col_idx + 1u) * GV_CAPTURE_SAMPLES) / GV_COLS;
                }
                c = &v->col[v->col_idx];
            }
        }
        v->sample_count++;

        lo_i = sin_q15((uint16_t)(v->nco_phase + 16384u));
        lo_q = sin_q15(v->nco_phase);
        v->nco_phase += v->nco_inc;

        mi = (int16_t)(((int32_t)i0 * lo_i - (int32_t)q0 * lo_q) >> 15);
        mq = (int16_t)(((int32_t)i0 * lo_q + (int32_t)q0 * lo_i) >> 15);

        if (c) {
            env_put(&c->lo[GV_IN_I], &c->hi[GV_IN_I], i0);
            env_put(&c->lo[GV_IN_Q], &c->hi[GV_IN_Q], q0);
            env_put(&c->lo[GV_MIX_I], &c->hi[GV_MIX_I], mi);
            env_put(&c->lo[GV_MIX_Q], &c->hi[GV_MIX_Q], mq);
        }

        v->i_acc += mi;
        v->q_acc += mq;
        v->decim_ctr++;

        if (v->decim_ctr < DECIM) continue;
        v->decim_ctr = 0;

        {
            int16_t di = (int16_t)(v->i_acc / DECIM);
            int16_t dq = (int16_t)(v->q_acc / DECIM);
            uint8_t was_burst = v->burst;
            uint8_t flags;

            v->i_acc = 0;
            v->q_acc = 0;
            v->dec_count++;

            dphi = (int32_t)di * v->prev_q - (int32_t)dq * v->prev_i;
            dphi >>= 12;
            if (dphi > 32767) dphi = 32767;
            if (dphi < -32768) dphi = -32768;

            v->prev_i = di;
            v->prev_q = dq;

            pwr = (uint32_t)abs32(di) + (uint32_t)abs32(dq);
            v->pavg = (v->pavg * 15u + pwr) >> 4;
            if (!v->burst)
                v->noise = (v->noise * 31u + (v->pavg < 300u ? 300u : v->pavg)) >> 5;

            if (v->pavg > threshold_of(v->noise)) {
                v->burst = 1u;
                v->burst_hang = BURST_HANG;
            } else if (v->burst_hang != 0u) {
                v->burst_hang--;
            } else {
                v->burst = 0u;
            }
            if (v->burst && !was_burst) {
                v->burst_start = v->dec_count;
                if (c) v->burst_total++;
                /* A burst before the pre-burst ring is full is not shown. */
                if (v->live == LIVE_ARMED && v->live_wait >= GV_SPEC_PRE) {
                    if (v->live_skip != 0u) v->live_skip--;
                    else live_start(v);
                }
            }

            v->favg = (int16_t)((7 * (int32_t)v->favg + dphi) / 8);
            v->dev = (int16_t)((15 * (int32_t)v->dev + abs32(dphi - v->favg)) / 16);
            flags = decoder_flags(v);

            if (c) {
                uint16_t p = clamp_u16(v->pavg);

                env_put(&c->lo[GV_DEC_I], &c->hi[GV_DEC_I], di);
                env_put(&c->lo[GV_DEC_Q], &c->hi[GV_DEC_Q], dq);
                env_put(&c->dphi_lo, &c->dphi_hi, (int16_t)dphi);
                c->favg = v->favg;
                c->dev = v->dev;
                if (p > c->pavg) c->pavg = p;
                c->noise = clamp_u16(v->noise);
                c->flags |= flags;

                if (v->cons_n < GV_CONST_POINTS && (v->dec_count % CONS_EVERY) == 0u) {
                    v->cons_i[v->cons_n] = di;
                    v->cons_q[v->cons_n] = dq;
                    v->cons_n++;
                }
            }
        }
    }

    spectrum_column(v, iq, n_samples);
}

/*------------------------------------------------------------- drawing ----*/

static char *u32_to_str(char *p, uint32_t x)
{
    char tmp[10];
    int n = 0;

    do { tmp[n++] = (char)('0' + x % 10u); x /= 10u; } while (x != 0u);
    while (n > 0) *p++ = tmp[--n];
    *p = '\0';
    return p;
}

static uint16_t text_w(const char *s)
{
    uint16_t n = 0u;
    while (*s++) n++;
    return (uint16_t)(n * 6u);
}

/* Leaves 12 px under the box for the time axis labels. */
static box_t plot_box(const tft_t *tft)
{
    box_t b;
    b.x0 = 6u;
    b.y0 = 28u;
    b.w = (uint16_t)(tft->w - 12u);
    b.h = (uint16_t)(tft->h - 44u);
    return b;
}

static void draw_frame(tft_t *tft, const char *title, uint8_t page)
{
    char buf[8];
    char *p;

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 6, 6, title, TFT_WHITE, TFT_BLACK, 2);

    p = u32_to_str(buf, page + 1u);
    *p++ = '/';
    u32_to_str(p, VIEW_COUNT);
    tft_draw_text(tft, (uint16_t)(tft->w - 6u - text_w(buf)), 4, buf, TFT_YELLOW, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(tft->w - 48u), 15, "K1> K2<", TFT_GRAY, TFT_BLACK, 1);
}

/* "0" under the left edge, capture length in ms under the right edge. */
static void draw_time_axis(tft_t *tft, const graph_viewer_t *v, const box_t *b)
{
    uint32_t us10 = (GV_CAPTURE_SAMPLES * 10u) / (v->cfg.sample_rate_hz / 1000u);  /* 0.1 ms units */
    char buf[12];
    char *p = u32_to_str(buf, us10 / 10u);
    uint16_t y = (uint16_t)(b->y0 + b->h + 2u);

    *p++ = '.';
    p = u32_to_str(p, us10 % 10u);
    *p++ = 'M'; *p++ = 'S'; *p = '\0';

    tft_draw_text(tft, b->x0, y, "0", TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(b->x0 + b->w - text_w(buf)), y, buf, TFT_GRAY, TFT_BLACK, 1);
}

/* Colored labels in one row inside the plot area. */
static void draw_legend(tft_t *tft, const box_t *b, const char *const *names, const uint16_t *colors, uint8_t n)
{
    uint16_t x = (uint16_t)(b->x0 + 4u);
    uint8_t i;

    for (i = 0u; i < n; i++) {
        tft_draw_text(tft, x, (uint16_t)(b->y0 + 3u), names[i], colors[i], TFT_BLACK, 1);
        x = (uint16_t)(x + text_w(names[i]) + 6u);
    }
}

static void draw_axis_box(tft_t *tft, uint16_t x, uint16_t y, uint16_t w, uint16_t h)
{
    tft_draw_rect(tft, x, y, w, h, TFT_GRAY);
    tft_draw_hline(tft, (uint16_t)(x + 2u), (uint16_t)(y + h / 2u), (uint16_t)(w - 4u), TFT_GRAY);
    tft_draw_vline(tft, (uint16_t)(x + w / 2u), (uint16_t)(y + 2u), (uint16_t)(h - 4u), TFT_GRAY);
}

static void draw_vline_clipped(tft_t *tft, uint16_t x, int16_t y1, int16_t y2, uint16_t ymin, uint16_t ymax, uint16_t color)
{
    int16_t lo = y1;
    int16_t hi = y2;

    if (lo > hi) { int16_t tt = lo; lo = hi; hi = tt; }
    if (hi < (int16_t)ymin || lo > (int16_t)ymax) return;

    if (lo < (int16_t)ymin) lo = (int16_t)ymin;
    if (hi > (int16_t)ymax) hi = (int16_t)ymax;

    tft_draw_vline(tft, x, (uint16_t)lo, (uint16_t)(hi - lo + 1), color);
}

/* How a column field is read: kind 0 = int16, 1 = uint16, 2 = threshold of uint16 noise. */
enum { COL_I16 = 0, COL_U16, COL_THR };

/* Field of col[c], addressed by a pointer to the same field in col[0]. */
static int32_t col_val(const void *field0, uint16_t c, uint8_t kind)
{
    const uint8_t *p = (const uint8_t *)field0 + (uint32_t)c * sizeof(gv_col_t);

    switch (kind) {
    case COL_I16: return *(const int16_t *)p;
    case COL_U16: return *(const uint16_t *)p;
    default:      return (int32_t)threshold_of(*(const uint16_t *)p);
    }
}

static uint16_t x_to_col(const box_t *b, uint16_t x)
{
    return (uint16_t)(((uint32_t)x * GV_COLS) / b->w);
}

static int32_t col_scale(const void *lo, const void *hi, uint8_t kind, int32_t m)
{
    uint16_t c;

    for (c = 0u; c < GV_COLS; c++) {
        int32_t a = abs32(col_val(lo, c, kind));
        int32_t b = abs32(col_val(hi, c, kind));
        if (a > m) m = a;
        if (b > m) m = b;
    }
    return m + (m >> 3);
}

/* COL_I16: zero in the middle. Unsigned kinds: zero at the bottom. */
static int16_t value_y(const box_t *b, int32_t val, int32_t scale, uint8_t kind)
{
    if (kind != COL_I16)
        return (int16_t)(b->y0 + b->h - 3 - (val * (int32_t)(b->h - 6u)) / scale);
    return (int16_t)(b->y0 + b->h / 2u - (val * (int32_t)(b->h / 2u - 3u)) / scale);
}

/* Min/max envelope over the whole capture; lo == hi gives a plain line. */
static void draw_env(tft_t *tft, const box_t *b, const void *lo, const void *hi, uint8_t kind,
                     int32_t scale, uint16_t color)
{
    uint16_t x;
    int16_t pt = 0, pb = 0;

    for (x = 0u; x < b->w; x++) {
        uint16_t c = x_to_col(b, x);
        int16_t t = value_y(b, col_val(hi, c, kind), scale, kind);
        int16_t bo = value_y(b, col_val(lo, c, kind), scale, kind);

        if (x == 0u) { pt = t; pb = bo; }
        draw_vline_clipped(tft, (uint16_t)(b->x0 + x), (t < pb) ? t : pb, (bo > pt) ? bo : pt,
                           (uint16_t)(b->y0 + 1u), (uint16_t)(b->y0 + b->h - 2u), color);
        pt = t;
        pb = bo;
    }
}

/* Decoder flag as a step line: low at the bottom, high at level/16 of the box. */
static void draw_flag(tft_t *tft, const graph_viewer_t *v, const box_t *b, uint8_t mask, uint8_t level, uint16_t color)
{
    uint16_t x;
    int16_t prev = 0;
    int16_t y_lo = (int16_t)(b->y0 + b->h - 3u);
    int16_t y_hi = (int16_t)(y_lo - ((b->h - 6u) * level) / 16u);

    for (x = 0u; x < b->w; x++) {
        int16_t y = (v->col[x_to_col(b, x)].flags & mask) ? y_hi : y_lo;

        if (x == 0u) prev = y;
        draw_vline_clipped(tft, (uint16_t)(b->x0 + x), prev, y, (uint16_t)(b->y0 + 1u), (uint16_t)(b->y0 + b->h - 2u), color);
        prev = y;
    }
}

static void draw_pair(tft_t *tft, const graph_viewer_t *v, uint8_t ch, int32_t min_scale, const char *const *names)
{
    static const uint16_t colors[2] = { TFT_CYAN, TFT_YELLOW };
    box_t b = plot_box(tft);
    const gv_col_t *c0 = &v->col[0];
    int32_t scale = col_scale(&c0->lo[ch], &c0->hi[ch], COL_I16, min_scale);
    int32_t s2 = col_scale(&c0->lo[ch + 1u], &c0->hi[ch + 1u], COL_I16, min_scale);

    if (s2 > scale) scale = s2;

    draw_axis_box(tft, b.x0, b.y0, b.w, b.h);
    draw_env(tft, &b, &c0->lo[ch], &c0->hi[ch], COL_I16, scale, TFT_CYAN);
    draw_env(tft, &b, &c0->lo[ch + 1u], &c0->hi[ch + 1u], COL_I16, scale, TFT_YELLOW);
    draw_legend(tft, &b, names, colors, 2u);
    draw_time_axis(tft, v, &b);
}

static uint16_t heat(uint8_t v)
{
    uint8_t t = (uint8_t)((v & 63u) << 2);

    switch (v >> 6) {
    case 0:  return TFT_RGB(0, 0, t);
    case 1:  return TFT_RGB(0, t, 255);
    case 2:  return TFT_RGB(t, 255, 255 - t);
    default: return TFT_RGB(255, 255 - t, 0);
    }
}

/* Color/height scale of the live spectrum: 0 at the noise floor, 255 at +96 steps (~36 dB). */
#define SPEC_SPAN 96u

static uint8_t spec_level(const graph_viewer_t *v, uint8_t x)
{
    uint32_t d;

    if (x <= v->live_lo) return 0u;
    d = ((uint32_t)(x - v->live_lo) * 255u) / SPEC_SPAN;
    return (uint8_t)(d > 255u ? 255u : d);
}

/* Half of the shown band in kHz, e.g. 562 for 4.5 MS/s. */
static uint32_t spec_half_khz(const graph_viewer_t *v)
{
    return (v->cfg.sample_rate_hz / GV_FFT_N) * (GV_SPEC_BINS / 2u) / 1000u;
}

/* "-562K" / "+562K" */
static void khz_label(char *buf, char sign, uint32_t khz)
{
    char *p;

    buf[0] = sign;
    p = u32_to_str(&buf[1], khz);
    *p++ = 'K';
    *p = '\0';
}

/* Spectrogram geometry: one pixel column per FFT, bh pixels per bin, labels on the right. */
typedef struct {
    uint16_t xs, ys, bh, gw, gh;
} spec_geom_t;

static spec_geom_t spec_geom(const tft_t *tft)
{
    box_t b = plot_box(tft);
    spec_geom_t g;

    g.xs = (uint16_t)(b.x0 + 1u);
    g.ys = (uint16_t)(b.y0 + 1u);
    g.bh = (uint16_t)((b.h - 2u) / GV_SPEC_BINS);
    g.gw = (uint16_t)(b.w - 2u - 38u);
    g.gh = (uint16_t)(g.bh * GV_SPEC_BINS);
    return g;
}

/* Waterfall geometry: GV_WF_TRACES lines, oldest at the top, each newer one lower and shifted right. */
enum { WF_SKEW = 2, WF_AMP = 64 };

static void wf_geom(const tft_t *tft, uint16_t *tw, uint16_t *step)
{
    box_t b = plot_box(tft);
    *tw = (uint16_t)(b.w - 4u - WF_SKEW * (GV_WF_TRACES - 1u));
    *step = (uint16_t)((b.h - WF_AMP - 6u) / (GV_WF_TRACES - 1u));
}

static int is_spectro(view_mode_t m) { return m == VIEW_PKT0_SPECTRO || m == VIEW_PKT1_SPECTRO; }

static void draw_spectro_frame(tft_t *tft, const graph_viewer_t *v)
{
    box_t b = plot_box(tft);
    spec_geom_t g = spec_geom(tft);
    uint16_t xl = (uint16_t)(g.xs + g.gw + 4u);
    int32_t bin_hz = (int32_t)(v->cfg.sample_rate_hz / GV_FFT_N);
    int32_t ch_off = (int32_t)v->cfg.channel_freq_hz - (int32_t)v->cfg.center_freq_hz;
    int32_t ch_bin = GV_SPEC_BINS / 2 + (ch_off + (ch_off < 0 ? -bin_hz / 2 : bin_hz / 2)) / bin_hz;
    char buf[8];

    tft_draw_rect(tft, b.x0, b.y0, (uint16_t)(g.gw + 2u), (uint16_t)(g.gh + 2u), TFT_GRAY);

    khz_label(buf, '+', spec_half_khz(v));
    tft_draw_text(tft, xl, g.ys, buf, TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, xl, (uint16_t)(g.ys + (GV_SPEC_BINS / 2u) * g.bh - 4u), "0", TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, '-', spec_half_khz(v));
    tft_draw_text(tft, xl, (uint16_t)(g.ys + g.gh - 8u), buf, TFT_GRAY, TFT_BLACK, 1);
    if (ch_bin >= 0 && ch_bin < GV_SPEC_BINS)
        tft_draw_text(tft, xl, (uint16_t)(g.ys + (GV_SPEC_BINS - 1u - (uint16_t)ch_bin) * g.bh + g.bh / 2u - 3u),
                      "<CH", TFT_WHITE, TFT_BLACK, 1);

    tft_draw_text(tft, b.x0, (uint16_t)(b.y0 + b.h + 2u), "TIME >", TFT_GRAY, TFT_BLACK, 1);
}

static void draw_waterfall_frame(tft_t *tft, const graph_viewer_t *v)
{
    box_t b = plot_box(tft);
    uint16_t tw, step;
    char buf[8];

    wf_geom(tft, &tw, &step);
    tft_draw_rect(tft, b.x0, b.y0, b.w, b.h, TFT_GRAY);

    khz_label(buf, '-', spec_half_khz(v));
    tft_draw_text(tft, b.x0, (uint16_t)(b.y0 + b.h + 2u), buf, TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u + tw / 2u), (uint16_t)(b.y0 + b.h + 2u), "0", TFT_GRAY, TFT_BLACK, 1);
    khz_label(buf, '+', spec_half_khz(v));
    tft_draw_text(tft, (uint16_t)(b.x0 + 2u + tw - text_w(buf)), (uint16_t)(b.y0 + b.h + 2u), buf, TFT_GRAY, TFT_BLACK, 1);
}

static void live_message(graph_viewer_t *v, const char *msg, uint16_t color)
{
    box_t b = plot_box(v->tft);
    tft_draw_text(v->tft, (uint16_t)(b.x0 + 8u), (uint16_t)(b.y0 + b.h / 2u - 4u), msg, color, TFT_BLACK, 1);
}

/* Entering a spectrum view: draw axes, then wait for a burst in new data. */
static void live_arm(graph_viewer_t *v, tft_t *tft, uint8_t skip)
{
    uint16_t n;

    v->tft = tft;
    v->live = LIVE_ARMED;
    v->live_skip = skip;
    v->live_x = 0u;
    v->live_wait = 0u;
    v->spec_wr = 0u;
    for (n = 0u; n < GV_SPEC_BINS; n++) v->wf_acc[n] = 0u;

    if (is_spectro(v->mode)) draw_spectro_frame(tft, v);
    else draw_waterfall_frame(tft, v);
    live_message(v, "WAITING FOR PACKET...", TFT_YELLOW);
}

static void live_timeout(graph_viewer_t *v)
{
    v->live = LIVE_OFF;
    live_message(v, "NO PACKET FOUND      ", TFT_RED);
}

/* Burst found: noise floor from the pre-burst ring, then draw the ring (oldest first). */
static void live_start(graph_viewer_t *v)
{
    box_t b = plot_box(v->tft);
    uint32_t sum = 0u;
    uint16_t c, n;

    for (c = 0u; c < GV_SPEC_PRE; c++)
        for (n = 0u; n < GV_SPEC_BINS; n++) sum += v->spec_pre[c][n];
    v->live_lo = (uint8_t)(sum / (GV_SPEC_PRE * GV_SPEC_BINS) + 20u);   /* ~7.5 dB above mean noise */

    tft_fill_rect(v->tft, (uint16_t)(b.x0 + 1u), (uint16_t)(b.y0 + 1u), (uint16_t)(b.w - 2u), (uint16_t)(b.h - 2u), TFT_BLACK);
    if (is_spectro(v->mode)) draw_spectro_frame(v->tft, v);
    else draw_waterfall_frame(v->tft, v);

    v->live = LIVE_DRAW;
    for (c = 0u; c < GV_SPEC_PRE && v->live == LIVE_DRAW; c++)
        live_column(v, v->spec_pre[(v->spec_wr + c) % GV_SPEC_PRE]);
}

static void live_spectro_column(graph_viewer_t *v, const uint8_t *col)
{
    spec_geom_t g = spec_geom(v->tft);
    uint16_t x = (uint16_t)(g.xs + v->live_x);
    uint16_t r;

    tft_set_window(v->tft, x, g.ys, x, (uint16_t)(g.ys + g.gh - 1u));
    for (r = 0u; r < GV_SPEC_BINS; r++)
        spi_tft_repeat16(v->tft->spi, heat(spec_level(v, col[GV_SPEC_BINS - 1u - r])), g.bh);

    if (v->live_x == GV_SPEC_PRE)   /* burst start marker */
        tft_draw_vline(v->tft, x, (uint16_t)(g.ys + g.gh + 1u), 4u, TFT_WHITE);

    if (++v->live_x >= g.gw) v->live = LIVE_OFF;
}

static void live_waterfall_column(graph_viewer_t *v, const uint8_t *col)
{
    box_t b = plot_box(v->tft);
    uint16_t tw, step, t, x, n;
    uint16_t x0, color;
    int16_t base, prev;

    for (n = 0u; n < GV_SPEC_BINS; n++) v->wf_acc[n] += col[n];
    if (++v->live_x % GV_WF_EVERY != 0u) return;

    wf_geom(v->tft, &tw, &step);
    t = (uint16_t)(v->live_x / GV_WF_EVERY - 1u);
    x0 = (uint16_t)(b.x0 + 2u + t * WF_SKEW);
    base = (int16_t)(b.y0 + 3u + WF_AMP + t * step);
    color = heat((uint8_t)(70u + (t * 185u) / (GV_WF_TRACES - 1u)));
    prev = base;

    for (x = 0u; x < tw; x++) {
        uint32_t pos = ((uint32_t)x * (GV_SPEC_BINS - 1u) * 256u) / (tw - 1u);
        uint16_t i = (uint16_t)(pos >> 8);
        uint16_t fr = (uint16_t)(pos & 255u);
        uint16_t a0 = v->wf_acc[i];
        uint16_t a1 = v->wf_acc[(i + 1u < GV_SPEC_BINS) ? i + 1u : i];
        uint8_t avg = (uint8_t)((((uint32_t)a0 * (256u - fr) + (uint32_t)a1 * fr) >> 8) / GV_WF_EVERY);
        int16_t y = (int16_t)(base - ((int32_t)spec_level(v, avg) * WF_AMP) / 255);

        /* Newer lines hide the older ones behind them: blank down to the baseline. */
        if (y < base)
            draw_vline_clipped(v->tft, (uint16_t)(x0 + x), (int16_t)(y + 1), base, (uint16_t)(b.y0 + 1u), (uint16_t)(b.y0 + b.h - 2u), TFT_BLACK);
        if (x > 0u)
            draw_vline_clipped(v->tft, (uint16_t)(x0 + x), prev, y, (uint16_t)(b.y0 + 1u), (uint16_t)(b.y0 + b.h - 2u), color);
        prev = y;
    }

    for (n = 0u; n < GV_SPEC_BINS; n++) v->wf_acc[n] = 0u;
    if (t + 1u >= GV_WF_TRACES) v->live = LIVE_OFF;
}

static void live_column(graph_viewer_t *v, const uint8_t *col)
{
    if (is_spectro(v->mode)) live_spectro_column(v, col);
    else live_waterfall_column(v, col);
}

static void draw_constellation(tft_t *tft, graph_viewer_t *v)
{
    uint16_t side = (uint16_t)(tft->h - 40u);
    uint16_t x0 = (uint16_t)((tft->w - side) / 2u);
    uint16_t y0 = 30u;
    int32_t scale = 64;
    uint16_t i;
    int16_t cx, cy;

    for (i = 0u; i < v->cons_n; i++) {
        if (abs32(v->cons_i[i]) > scale) scale = abs32(v->cons_i[i]);
        if (abs32(v->cons_q[i]) > scale) scale = abs32(v->cons_q[i]);
    }
    scale += scale >> 3;

    draw_axis_box(tft, x0, y0, side, side);
    cx = (int16_t)(x0 + side / 2u);
    cy = (int16_t)(y0 + side / 2u);

    for (i = 0u; i < v->cons_n; i++) {
        int16_t x = (int16_t)(cx + (v->cons_i[i] * (int32_t)(side / 2u - 3u)) / scale);
        int16_t y = (int16_t)(cy - (v->cons_q[i] * (int32_t)(side / 2u - 3u)) / scale);
        tft_fill_rect(tft, (uint16_t)(x - 1), (uint16_t)(y - 1), 3, 3, TFT_CYAN);
    }
}

static void draw_dphi(tft_t *tft, graph_viewer_t *v)
{
    static const char *const names[1] = { "DPHI" };
    static const uint16_t colors[1] = { TFT_MAGENTA };
    box_t b = plot_box(tft);
    const gv_col_t *c0 = &v->col[0];

    draw_axis_box(tft, b.x0, b.y0, b.w, b.h);
    draw_env(tft, &b, &c0->dphi_lo, &c0->dphi_hi, COL_I16, col_scale(&c0->dphi_lo, &c0->dphi_hi, COL_I16, 700), TFT_MAGENTA);
    draw_legend(tft, &b, names, colors, 1u);
    draw_time_axis(tft, v, &b);
}

static void draw_power(tft_t *tft, graph_viewer_t *v)
{
    static const char *const names[4] = { "PAVG", "NOISE", "THR", "BURST" };
    static const uint16_t colors[4] = { TFT_GREEN, TFT_WHITE, TFT_YELLOW, TFT_RED };
    box_t b = plot_box(tft);
    const gv_col_t *c0 = &v->col[0];
    int32_t scale = col_scale(&c0->pavg, &c0->pavg, COL_U16, 64);
    int32_t s_thr = col_scale(&c0->noise, &c0->noise, COL_THR, 64);

    if (s_thr > scale) scale = s_thr;

    tft_draw_rect(tft, b.x0, b.y0, b.w, b.h, TFT_GRAY);
    draw_flag(tft, v, &b, GV_F_BURST, 15u, TFT_RED);
    draw_env(tft, &b, &c0->noise, &c0->noise, COL_U16, scale, TFT_WHITE);
    draw_env(tft, &b, &c0->noise, &c0->noise, COL_THR, scale, TFT_YELLOW);
    draw_env(tft, &b, &c0->pavg, &c0->pavg, COL_U16, scale, TFT_GREEN);
    draw_legend(tft, &b, names, colors, 4u);
    draw_time_axis(tft, v, &b);
}

static void draw_bit_decoder(tft_t *tft, graph_viewer_t *v)
{
    static const char *const names[6] = { "DPHI", "AFC", "DEV", "SYNC", "PRE", "PKT" };
    static const uint16_t colors[6] = { TFT_MAGENTA, TFT_CYAN, TFT_WHITE, TFT_RED, TFT_YELLOW, TFT_GREEN };
    box_t b = plot_box(tft);
    const gv_col_t *c0 = &v->col[0];
    int32_t scale = col_scale(&c0->dphi_lo, &c0->dphi_hi, COL_I16, 700);

    draw_axis_box(tft, b.x0, b.y0, b.w, b.h);
    draw_env(tft, &b, &c0->dphi_lo, &c0->dphi_hi, COL_I16, scale, TFT_MAGENTA);
    draw_env(tft, &b, &c0->favg, &c0->favg, COL_I16, scale, TFT_CYAN);
    draw_env(tft, &b, &c0->dev, &c0->dev, COL_I16, scale, TFT_WHITE);
    draw_flag(tft, v, &b, GV_F_SYNC, 14u, TFT_RED);
    draw_flag(tft, v, &b, GV_F_PRE, 13u, TFT_YELLOW);
    draw_flag(tft, v, &b, GV_F_PKT, 12u, TFT_GREEN);
    draw_legend(tft, &b, names, colors, 6u);
    draw_time_axis(tft, v, &b);
}

static void draw_decoder_timeline(tft_t *tft, graph_viewer_t *v)
{
    static const char *const names[4] = { "SYNC", "PRE", "PKT", "BUR" };
    static const uint8_t masks[4] = { GV_F_SYNC, GV_F_PRE, GV_F_PKT, GV_F_BURST };
    static const uint16_t colors[4] = { TFT_RED, TFT_YELLOW, TFT_GREEN, TFT_CYAN };
    box_t b = plot_box(tft);
    uint16_t lane = b.h / 4u;
    uint16_t x;
    uint8_t l;

    tft_draw_rect(tft, b.x0, b.y0, b.w, b.h, TFT_GRAY);
    for (l = 1u; l < 4u; l++)
        tft_draw_hline(tft, b.x0, (uint16_t)(b.y0 + l * lane), b.w, TFT_GRAY);

    for (x = 0u; x < b.w; x++) {
        uint8_t f = v->col[x_to_col(&b, x)].flags;
        uint16_t xx = (uint16_t)(b.x0 + x);

        if (f & GV_F_RES) {
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
    draw_time_axis(tft, v, &b);
}

static void draw_capture_progress(tft_t *tft, const graph_viewer_t *v)
{
    uint16_t bw = (uint16_t)(tft->w - 40u);
    uint32_t done = (v->sample_count * (uint32_t)bw) / (GV_WARMUP_SAMPLES + GV_CAPTURE_SAMPLES);

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 20, 80, "CAPTURE", TFT_WHITE, TFT_BLACK, 2);
    tft_draw_rect(tft, 20, 110, bw, 16, TFT_GRAY);
    if (done > (uint32_t)(bw - 4u)) done = (uint32_t)(bw - 4u);
    tft_fill_rect(tft, 22, 112, (uint16_t)done, 12, TFT_GREEN);
}

void graph_viewer_draw(graph_viewer_t *v, tft_t *tft)
{
    static const char *const names[VIEW_COUNT] = {
        "INPUT I/Q",
        "P0 SPECTR",
        "P0 WATERF",
        "P1 SPECTR",
        "P1 WATERF",
        "NCO MIXER",
        "CIC3 DEC",
        "CONSTELL",
        "FM DPHI",
        "PWR BURST",
        "BIT DEC",
        "DECODER"
    };
    static const char *const iq_names[2]  = { "I", "Q" };
    static const char *const mix_names[2] = { "MIX I", "MIX Q" };
    static const char *const dec_names[2] = { "DEC I", "DEC Q" };

    v->live = LIVE_OFF;

    if (!v->done) {
        draw_capture_progress(tft, v);
        return;
    }

    draw_frame(tft, names[v->mode], (uint8_t)v->mode);

    switch (v->mode) {
    case VIEW_INPUT_IQ:       draw_pair(tft, v, GV_IN_I, 3000, iq_names); break;
    case VIEW_PKT0_SPECTRO:
    case VIEW_PKT0_WATERFALL: live_arm(v, tft, 0u); break;
    case VIEW_PKT1_SPECTRO:
    case VIEW_PKT1_WATERFALL: live_arm(v, tft, 1u); break;
    case VIEW_MIXER_IQ:       draw_pair(tft, v, GV_MIX_I, 3000, mix_names); break;
    case VIEW_CIC_IQ:         draw_pair(tft, v, GV_DEC_I, 1800, dec_names); break;
    case VIEW_CONSTELLATION:  draw_constellation(tft, v); break;
    case VIEW_DPHI:           draw_dphi(tft, v); break;
    case VIEW_POWER:          draw_power(tft, v); break;
    case VIEW_BITDEC:         draw_bit_decoder(tft, v); break;
    case VIEW_DECODER:        draw_decoder_timeline(tft, v); break;
    default: break;
    }
}
