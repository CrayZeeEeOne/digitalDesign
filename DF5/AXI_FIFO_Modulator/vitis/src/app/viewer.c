#include "app/viewer.h"
#include "config.h"
#include "gfx/plot.h"
#include "app/view_time.h"
#include "app/view_freq.h"
#include "app/view_sd.h"

static const char *const view_names[VIEW_COUNT] = { "RAW I/Q", "BITS", "FFT", "WATERFALL", "SD CARD" };

/* Number of points the zoom window of each screen moves over. */
static uint16_t view_points(view_mode_t m)
{
    return (m == VIEW_FFT || m == VIEW_WATERFALL) ? VIEW_FREQ_POINTS : VIEW_TIME_POINTS;
}

/* STATIC: waterfall rows straight from the capture, oldest at the top. */
static const uint8_t *cap_row(void *ctx, uint16_t i)
{
    return ((const cap_data_t *)ctx)->wf[i];
}

void viewer_init(viewer_t *v)
{
    uint32_t n;

    for (n = 0u; n < sizeof(*v); n++) ((uint8_t *)v)[n] = 0u;
    v->mode = VIEW_RAW;
    v->state = VSTATE_STATIC;
    v->prog_total = 1u;
    v->source = "";
    v->fft_tag = "";
}

void viewer_set_mode(viewer_t *v, view_mode_t mode)
{
    v->mode = (mode < VIEW_COUNT) ? mode : VIEW_RAW;
}

int viewer_key(viewer_t *v, key_action_t a)
{
    zoom_t *z = &v->zoom[v->mode];
    uint16_t n = view_points(v->mode);

    if (a == KEY_NEXT) {
        v->mode = (view_mode_t)((v->mode + 1u) % VIEW_COUNT);
        return 1;
    }
    if (v->mode == VIEW_SD || v->state == VSTATE_LIVE) return 0;

    switch (a) {
    case KEY_ZOOM:
        zoom_cycle(z, n);
        return 1;
    case KEY_PAN_BACK:
        return zoom_pan(z, n, -1);
    case KEY_PAN_FWD:
        return zoom_pan(z, n, +1);
    default:
        return 0;
    }
}

void viewer_use_capture(viewer_t *v, const cap_data_t *cap)
{
    v->state = VSTATE_STATIC;
    v->cap = cap;
    if (!cap) return;
    v->fft = cap->fft;
    v->fft_tag = "MAX HOLD";
    v->wf.nrows = CAP_WF_ROWS;
    v->wf.row = cap_row;
    v->wf.ctx = (void *)cap;
    v->wf.span_ms10 = (CFG_CAPTURE_SAMPLES * 10u) / (CFG_SAMPLE_RATE_HZ / 1000u);
    v->wf.live = 0u;
}

void viewer_set_progress(viewer_t *v, uint32_t done, uint32_t total)
{
    v->prog_done = done;
    v->prog_total = total ? total : 1u;
}

static void draw_frame(tft_t *tft, const viewer_t *v, const zoom_t *z)
{
    view_mode_t m = v->mode;
    const char *hint;
    char buf[8];
    char *p;
    uint16_t x;

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 6, 6, view_names[m], TFT_WHITE, TFT_BLACK, 2);
    x = (uint16_t)(6u + 2u * plot_text_w(view_names[m]) + 6u);

    if (m != VIEW_SD && v->state == VSTATE_LIVE) {
        tft_draw_text(tft, x, 10, "LIVE", TFT_GREEN, TFT_BLACK, 1);
    } else if (m != VIEW_SD && v->state == VSTATE_PAUSE) {
        tft_draw_text(tft, x, 10, "PAUSE", TFT_YELLOW, TFT_BLACK, 1);
        x = (uint16_t)(x + 36u);
    }
    if (z->level && v->state != VSTATE_LIVE) {
        buf[0] = 'X';
        plot_u32_to_str(&buf[1], 1u << z->level);
        tft_draw_text(tft, (x > 150u) ? x : 150u, 6, buf, TFT_YELLOW, TFT_BLACK, 2);
    }

    p = plot_u32_to_str(buf, m + 1u);
    *p++ = '/';
    plot_u32_to_str(p, VIEW_COUNT);
    tft_draw_text(tft, (uint16_t)(tft->w - 6u - plot_text_w(buf)), 4, buf, TFT_YELLOW, TFT_BLACK, 1);
    if (m == VIEW_SD)                     hint = "K1>  K2 TEST+PLAY";
    else if (v->state == VSTATE_LIVE)     hint = "K1>  K2 PAUSE";
    else if (v->state == VSTATE_PAUSE)    hint = "K2 ZOOM K1+2 LIVE";
    else                                  hint = "K1>  K2 ZOOM";
    tft_draw_text(tft, (uint16_t)(tft->w - 6u - plot_text_w(hint)), 15, hint, TFT_GRAY, TFT_BLACK, 1);
}

static void draw_capture_progress(tft_t *tft, const viewer_t *v)
{
    uint16_t bw = (uint16_t)(tft->w - 40u);
    uint32_t done = (v->prog_done >= v->prog_total) ? (uint32_t)(bw - 4u)
                  : (v->prog_done / 64u) * (bw - 4u) / (v->prog_total / 64u + 1u);

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 20, 80, "CAPTURE", TFT_WHITE, TFT_BLACK, 2);
    tft_draw_text(tft, 20, 134, v->source, TFT_GRAY, TFT_BLACK, 1);
    tft_draw_rect(tft, 20, 110, bw, 16, TFT_GRAY);
    tft_fill_rect(tft, 22, 112, (uint16_t)done, 12, TFT_GREEN);
}

void viewer_draw(viewer_t *v, tft_t *tft, int full)
{
    const zoom_t *z = &v->zoom[v->mode];
    zoom_t z1 = { 0u, 0u };

    if (!v->cap && v->mode != VIEW_SD) {
        draw_capture_progress(tft, v);
        return;
    }
    if (v->state == VSTATE_LIVE) z = &z1;      /* live: always the whole picture */
    if (full) draw_frame(tft, v, z);

    switch (v->mode) {
    case VIEW_RAW:       view_raw(tft, v->cap, z, full); break;
    case VIEW_BITS:      view_bits(tft, v->cap, z, full); break;
    case VIEW_FFT:       view_fft(tft, v->fft, v->fft_tag, z, full); break;
    case VIEW_WATERFALL: view_waterfall(tft, &v->wf, v->cap, z, full); break;
    case VIEW_SD:        if (full) view_sd(tft, v->sd, v->sd_fmt); break;
    default: break;
    }
}
