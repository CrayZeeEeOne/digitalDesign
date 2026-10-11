#include "graph_viewer.h"
#include <stdio.h>
#include "dsp_tables.h"

#define DECIM          16
#define SPEC_N         64
#define SPEC_H         112
#define SPEC_W         112

#define PLOT_X         8
#define PLOT_Y         42
#define PLOT_W         224
#define PLOT_H         224

static int16_t abs16(int16_t x) { return (x < 0) ? (int16_t)-x : x; }
static int32_t abs32(int32_t x) { return (x < 0) ? -x : x; }

static int16_t sin_q15_from_lut(uint16_t phase)
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

static uint16_t heat_color(uint8_t v)
{
    uint8_t r, g, b;
    if (v < 64) {
        r = 0;
        g = (uint8_t)(v * 2);
        b = (uint8_t)(40 + v * 3);
    } else if (v < 128) {
        uint8_t t = (uint8_t)(v - 64);
        r = 0;
        g = (uint8_t)(130 + t);
        b = (uint8_t)(220 - t * 2);
    } else if (v < 192) {
        uint8_t t = (uint8_t)(v - 128);
        r = (uint8_t)(t * 3);
        g = (uint8_t)(190 + t / 2);
        b = 0;
    } else {
        uint8_t t = (uint8_t)(v - 192);
        r = 255;
        g = (uint8_t)(220 - t * 2);
        b = 0;
    }
    return TFT_RGB(r, g, b);
}

static uint16_t sat_u16(uint32_t v)
{
    return (v > 65535u) ? 65535u : (uint16_t)v;
}

static void shift_i16(int16_t *buf, int16_t v)
{
    int i;
    for (i = 0; i < 239; i++) buf[i] = buf[i + 1];
    buf[239] = v;
}

static void shift_u16(uint16_t *buf, uint16_t v)
{
    int i;
    for (i = 0; i < 239; i++) buf[i] = buf[i + 1];
    buf[239] = v;
}

static void shift_u8(uint8_t *buf, uint8_t v)
{
    int i;
    for (i = 0; i < 239; i++) buf[i] = buf[i + 1];
    buf[239] = v;
}

static void update_spectrum(graph_viewer_t *v)
{
    int k, n;
    uint8_t row;

    for (k = 0; k < 56; k++) {
        int32_t re = 0;
        int32_t im = 0;
        uint16_t phase = 0;
        uint16_t step = (uint16_t)((k * 65536u) / SPEC_N);

        for (n = 0; n < SPEC_N; n++) {
            int16_t c = sin_q15_from_lut((uint16_t)(phase + 16384u));
            int16_t s = sin_q15_from_lut(phase);
            int16_t x = (int16_t)((v->spec_hist[n] * dsp_hann_q15[n * (DSP_FFT_N / SPEC_N)]) >> 15);
            re += (x * c) >> 10;
            im -= (x * s) >> 10;
            phase = (uint16_t)(phase + step);
        }

        {
            uint32_t mag = (uint32_t)(abs32(re) + abs32(im));
            uint8_t level = (mag > 255u * 48u) ? 255u : (uint8_t)(mag / 48u);
            v->spec_col[2 * k] = level;
            v->spec_col[2 * k + 1] = level;
        }
    }

    for (row = 0; row < SPEC_H; row++) {
        int x;
        for (x = 0; x < SPEC_W - 1; x++)
            v->spectrogram[row][x] = v->spectrogram[row][x + 1];
        v->spectrogram[row][SPEC_W - 1] = v->spec_col[SPEC_H - 1 - row];
    }

    for (row = 0; row < SPEC_H - 1; row++) {
        int x;
        for (x = 0; x < SPEC_W; x++)
            v->waterfall[row][x] = v->waterfall[row + 1][x];
    }
    for (k = 0; k < SPEC_W; k++)
        v->waterfall[SPEC_H - 1][k] = v->spec_col[k];
}

void graph_viewer_init(graph_viewer_t *v, const viewer_cfg_t *cfg)
{
    int i, y, x;

    v->cfg = *cfg;
    v->mode = VIEW_INPUT_IQ;

    v->nco_phase = 0;
    v->nco_inc = (uint16_t)((250000u * 65536u) / v->cfg.sample_rate_hz);

    v->i1 = v->i2 = v->i3 = 0;
    v->q1 = v->q2 = v->q3 = 0;
    v->ci0 = v->ci1 = v->ci2 = 0;
    v->cq0 = v->cq1 = v->cq2 = 0;
    v->decim_ctr = 0;

    v->prev_i = 0;
    v->prev_q = 0;
    v->favg = 0;
    v->pavg = 0;
    v->noise = 1;
    v->burst = 0;
    v->synced = 0;
    v->preamble = 0;
    v->pkt_active = 0;

    v->sample_count = 0;
    v->dec_count = 0;
    v->burst_count = 0;

    for (i = 0; i < 240; i++) {
        v->in_i[i] = v->in_q[i] = 0;
        v->mix_i[i] = v->mix_q[i] = 0;
        v->dec_i[i] = v->dec_q[i] = 0;
        v->dphi[i] = 0;
        v->pwr[i] = v->thr[i] = 0;
        v->burst_tl[i] = v->sync_tl[i] = v->pre_tl[i] = v->pkt_tl[i] = 0;
    }

    for (i = 0; i < 192; i++) {
        v->cons_i[i] = 0;
        v->cons_q[i] = 0;
    }
    v->cons_wr = 0;

    for (i = 0; i < SPEC_N; i++) v->spec_hist[i] = 0;
    for (i = 0; i < SPEC_H; i++) v->spec_col[i] = 0;
    v->spec_ctr = 0;

    for (y = 0; y < SPEC_H; y++)
        for (x = 0; x < SPEC_W; x++)
            v->spectrogram[y][x] = v->waterfall[y][x] = 0;
}

void graph_viewer_set_mode(graph_viewer_t *v, view_mode_t mode)
{
    v->mode = mode;
}

void graph_viewer_next(graph_viewer_t *v)
{
    v->mode = (view_mode_t)((v->mode + 1) % VIEW_COUNT);
}

void graph_viewer_prev(graph_viewer_t *v)
{
    if (v->mode == 0) v->mode = VIEW_COUNT - 1;
    else v->mode = (view_mode_t)(v->mode - 1);
}

void graph_viewer_process_block(graph_viewer_t *v, const int16_t *iq, uint32_t n_samples)
{
    uint32_t n;

    for (n = 0; n < n_samples; n++) {
        int16_t i = iq[2 * n];
        int16_t q = iq[2 * n + 1];
        int16_t s = sin_q15_from_lut(v->nco_phase);
        int16_t c = sin_q15_from_lut((uint16_t)(v->nco_phase + 16384u));
        int16_t mi, mq;

        v->sample_count++;
        v->nco_phase = (uint16_t)(v->nco_phase + v->nco_inc);

        mi = (int16_t)(((int32_t)i * c - (int32_t)q * s) >> 15);
        mq = (int16_t)(((int32_t)i * s + (int32_t)q * c) >> 15);

        if ((v->sample_count & 15u) == 0u) {
            shift_i16(v->in_i, i);
            shift_i16(v->in_q, q);
            shift_i16(v->mix_i, mi);
            shift_i16(v->mix_q, mq);
        }

        v->i1 += mi;
        v->i2 += v->i1;
        v->i3 += v->i2;
        v->q1 += mq;
        v->q2 += v->q1;
        v->q3 += v->q2;

        v->decim_ctr++;
        if (v->decim_ctr < DECIM) continue;
        v->decim_ctr = 0;

        {
            int32_t d1i = v->i3 - v->ci0;
            int32_t d2i = d1i - v->ci1;
            int32_t d3i = d2i - v->ci2;
            int32_t d1q = v->q3 - v->cq0;
            int32_t d2q = d1q - v->cq1;
            int32_t d3q = d2q - v->cq2;
            int16_t di, dq;
            int32_t dot, cross;
            int16_t dphi;
            uint32_t power;
            uint16_t thr;

            v->ci0 = v->i3; v->ci1 = d1i; v->ci2 = d2i;
            v->cq0 = v->q3; v->cq1 = d1q; v->cq2 = d2q;

            di = (int16_t)(d3i >> 12);
            dq = (int16_t)(d3q >> 12);
            v->dec_count++;

            dot = (int32_t)di * v->prev_i + (int32_t)dq * v->prev_q;
            cross = (int32_t)dq * v->prev_i - (int32_t)di * v->prev_q;
            dphi = (int16_t)((cross * 16384) / (abs32(dot) + abs32(cross) + 1));
            v->prev_i = di;
            v->prev_q = dq;

            v->favg = (int16_t)(v->favg + ((dphi - v->favg) >> 4));
            power = (uint32_t)(di * di + dq * dq);
            v->pavg = v->pavg + ((power - v->pavg) >> 4);
            v->noise = v->noise + ((v->pavg - v->noise) >> 8);
            thr = sat_u16(v->noise * 8u);

            v->burst = (v->pavg > thr) ? 1u : ((v->pavg < (thr >> 1)) ? 0u : v->burst);
            if ((v->burst_tl[238] == 0u) && (v->burst != 0u)) v->burst_count++;

            v->preamble = (abs16(dphi - v->favg) < 900) ? 1u : 0u;
            v->synced = (v->burst && v->preamble) ? 1u : 0u;
            v->pkt_active = (v->synced && abs16(dphi) > 200) ? 1u : 0u;

            shift_i16(v->dec_i, di);
            shift_i16(v->dec_q, dq);
            shift_i16(v->dphi, dphi);
            shift_u16(v->pwr, sat_u16(v->pavg));
            shift_u16(v->thr, thr);

            shift_u8(v->burst_tl, v->burst);
            shift_u8(v->sync_tl, v->synced);
            shift_u8(v->pre_tl, v->preamble);
            shift_u8(v->pkt_tl, v->pkt_active);

            v->cons_i[v->cons_wr] = di;
            v->cons_q[v->cons_wr] = dq;
            v->cons_wr = (uint16_t)((v->cons_wr + 1u) % 192u);

            {
                int idx;
                for (idx = 0; idx < SPEC_N - 1; idx++)
                    v->spec_hist[idx] = v->spec_hist[idx + 1];
                v->spec_hist[SPEC_N - 1] = dphi;
            }

            v->spec_ctr++;
            if ((v->spec_ctr & 7u) == 0u)
                update_spectrum(v);
        }
    }
}

static void draw_axis(tft_t *tft, uint16_t color)
{
    tft_draw_rect(tft, PLOT_X, PLOT_Y, PLOT_W, PLOT_H, color);
    tft_draw_hline(tft, PLOT_X + 1, PLOT_Y + PLOT_H / 2, PLOT_W - 2, TFT_GRAY);
}

static void draw_trace_2(graph_viewer_t *v, tft_t *tft, const int16_t *a, const int16_t *b, int16_t scale)
{
    int x;
    (void)v;
    for (x = 0; x < PLOT_W; x++) {
        int ya = PLOT_Y + (PLOT_H / 2) - ((a[x] * (PLOT_H / 2 - 2)) / scale);
        int yb = PLOT_Y + (PLOT_H / 2) - ((b[x] * (PLOT_H / 2 - 2)) / scale);
        if (ya >= PLOT_Y && ya < PLOT_Y + PLOT_H) tft_draw_pixel(tft, (uint16_t)(PLOT_X + x), (uint16_t)ya, TFT_CYAN);
        if (yb >= PLOT_Y && yb < PLOT_Y + PLOT_H) tft_draw_pixel(tft, (uint16_t)(PLOT_X + x), (uint16_t)yb, TFT_YELLOW);
    }
}

static void draw_trace_1(tft_t *tft, const int16_t *a, int16_t scale, uint16_t color)
{
    int x;
    for (x = 0; x < PLOT_W; x++) {
        int y = PLOT_Y + (PLOT_H / 2) - ((a[x] * (PLOT_H / 2 - 2)) / scale);
        if (y >= PLOT_Y && y < PLOT_Y + PLOT_H) tft_draw_pixel(tft, (uint16_t)(PLOT_X + x), (uint16_t)y, color);
    }
}

static void draw_power(tft_t *tft, const uint16_t *p, const uint16_t *th, const uint8_t *burst)
{
    int x;
    uint32_t maxv = 1;
    for (x = 0; x < PLOT_W; x++) if (p[x] > maxv) maxv = p[x];
    for (x = 0; x < PLOT_W; x++) {
        int yp = PLOT_Y + PLOT_H - 2 - (int)((p[x] * (PLOT_H - 4)) / maxv);
        int yt = PLOT_Y + PLOT_H - 2 - (int)((th[x] * (PLOT_H - 4)) / maxv);
        if (yp >= PLOT_Y && yp < PLOT_Y + PLOT_H) tft_draw_pixel(tft, (uint16_t)(PLOT_X + x), (uint16_t)yp, TFT_CYAN);
        if (yt >= PLOT_Y && yt < PLOT_Y + PLOT_H) tft_draw_pixel(tft, (uint16_t)(PLOT_X + x), (uint16_t)yt, TFT_RED);
        if (burst[x]) tft_draw_vline(tft, (uint16_t)(PLOT_X + x), PLOT_Y + PLOT_H - 8, 6, TFT_GREEN);
    }
}

static void draw_heatmap(tft_t *tft, uint8_t src[SPEC_H][SPEC_W])
{
    int y, x;
    for (y = 0; y < SPEC_H; y++) {
        for (x = 0; x < SPEC_W; x++) {
            uint16_t c = heat_color(src[y][x]);
            tft_fill_rect(tft, (uint16_t)(PLOT_X + x * 2), (uint16_t)(PLOT_Y + y * 2), 2, 2, c);
        }
    }
    tft_draw_rect(tft, PLOT_X, PLOT_Y, PLOT_W, PLOT_H, TFT_GRAY);
}

static void draw_constellation(graph_viewer_t *v, tft_t *tft)
{
    int i;
    int cx = PLOT_X + PLOT_W / 2;
    int cy = PLOT_Y + PLOT_H / 2;

    tft_draw_rect(tft, PLOT_X, PLOT_Y, PLOT_W, PLOT_H, TFT_GRAY);
    tft_draw_hline(tft, PLOT_X + 1, (uint16_t)cy, PLOT_W - 2, TFT_GRAY);
    tft_draw_vline(tft, (uint16_t)cx, PLOT_Y + 1, PLOT_H - 2, TFT_GRAY);

    for (i = 0; i < 192; i++) {
        int idx = (v->cons_wr + i) % 192;
        int x = cx + (v->cons_i[idx] * (PLOT_W / 2 - 4)) / 4096;
        int y = cy - (v->cons_q[idx] * (PLOT_H / 2 - 4)) / 4096;
        if (x >= PLOT_X && x < PLOT_X + PLOT_W && y >= PLOT_Y && y < PLOT_Y + PLOT_H)
            tft_draw_pixel(tft, (uint16_t)x, (uint16_t)y, TFT_CYAN);
    }
}

void graph_viewer_draw(graph_viewer_t *v, tft_t *tft)
{
    char line[64];

    static const char *names[VIEW_COUNT] = {
        "Input I/Q",
        "Mixer I/Q",
        "CIC decimated I/Q",
        "Discriminator + Power",
        "Spectrogram",
        "Waterfall",
        "Constellation",
        "Decoder state"
    };

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 8, 8, names[v->mode], TFT_WHITE, TFT_BLACK, 2);
    tft_draw_text(tft, 8, 26, "KEY1 next  KEY2 prev", TFT_YELLOW, TFT_BLACK, 1);

    switch (v->mode) {
    case VIEW_INPUT_IQ:
        draw_axis(tft, TFT_GRAY);
        draw_trace_2(v, tft, v->in_i, v->in_q, 32767);
        break;

    case VIEW_MIXER_IQ:
        draw_axis(tft, TFT_GRAY);
        draw_trace_2(v, tft, v->mix_i, v->mix_q, 32767);
        break;

    case VIEW_CIC_IQ:
        draw_axis(tft, TFT_GRAY);
        draw_trace_2(v, tft, v->dec_i, v->dec_q, 8192);
        break;

    case VIEW_DPHI_POWER:
        draw_axis(tft, TFT_GRAY);
        draw_trace_1(tft, v->dphi, 16384, TFT_MAGENTA);
        draw_power(tft, v->pwr, v->thr, v->burst_tl);
        break;

    case VIEW_SPECTROGRAM:
        draw_heatmap(tft, v->spectrogram);
        break;

    case VIEW_WATERFALL:
        draw_heatmap(tft, v->waterfall);
        break;

    case VIEW_CONSTELLATION:
        draw_constellation(v, tft);
        break;

    case VIEW_DECODER: {
        int x;
        tft_draw_rect(tft, PLOT_X, PLOT_Y, PLOT_W, PLOT_H, TFT_GRAY);
        for (x = 0; x < PLOT_W; x++) {
            if (v->sync_tl[x])  tft_draw_vline(tft, (uint16_t)(PLOT_X + x), PLOT_Y + 24, 30, TFT_RED);
            if (v->pre_tl[x])   tft_draw_vline(tft, (uint16_t)(PLOT_X + x), PLOT_Y + 70, 30, TFT_YELLOW);
            if (v->pkt_tl[x])   tft_draw_vline(tft, (uint16_t)(PLOT_X + x), PLOT_Y + 116, 30, TFT_GREEN);
            if (v->burst_tl[x]) tft_draw_vline(tft, (uint16_t)(PLOT_X + x), PLOT_Y + 162, 30, TFT_CYAN);
        }
        tft_draw_text(tft, 12, 54,  "SYNC", TFT_RED, TFT_BLACK, 1);
        tft_draw_text(tft, 12, 100, "PRE",  TFT_YELLOW, TFT_BLACK, 1);
        tft_draw_text(tft, 12, 146, "PKT",  TFT_GREEN, TFT_BLACK, 1);
        tft_draw_text(tft, 12, 192, "BUR",  TFT_CYAN, TFT_BLACK, 1);
        break;
    }

    default:
        break;
    }

    snprintf(line, sizeof(line), "fs=%luHz dec=%lu bursts=%lu",
             (unsigned long)v->cfg.sample_rate_hz,
             (unsigned long)v->dec_count,
             (unsigned long)v->burst_count);
    tft_draw_text(tft, 8, 302, line, TFT_WHITE, TFT_BLACK, 1);
}

