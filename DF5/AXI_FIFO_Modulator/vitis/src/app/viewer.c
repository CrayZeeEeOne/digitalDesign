#include "app/viewer.h"
#include "config.h"
#include "gfx/plot.h"
#include "app/view_time.h"
#include "app/view_freq.h"

/*
 * NCO step that moves the channel to 0 Hz: (center - channel) / Fs * 2^16, rounded.
 * 64-bit math: 250 kHz * 2^16 does not fit in 32 bits.
 */
#define NCO_OFFSET_HZ ((int64_t)CFG_CENTER_FREQ_HZ - (int64_t)CFG_CHANNEL_FREQ_HZ)
#define NCO_INC ((uint16_t)((NCO_OFFSET_HZ * 65536 + (NCO_OFFSET_HZ >= 0 ? 1 : -1) * (int64_t)(CFG_SAMPLE_RATE_HZ / 2)) \
                            / (int64_t)CFG_SAMPLE_RATE_HZ))

/* Bit clock step at the decimated rate: 2^16 * bitrate / (Fs / DECIM_R), rounded. */
#define BIT_INC ((uint16_t)(((uint64_t)CFG_BITRATE * 65536u * DECIM_R + CFG_SAMPLE_RATE_HZ / 2u) / CFG_SAMPLE_RATE_HZ))

static const char *const view_names[VIEW_COUNT] = { "RAW I/Q", "BITS", "FFT", "WATERFALL" };

/* Number of points the zoom window of each screen moves over. */
static uint16_t view_points(view_mode_t m)
{
    return (m == VIEW_FFT || m == VIEW_WATERFALL) ? VIEW_FREQ_POINTS : VIEW_TIME_POINTS;
}

void viewer_init(viewer_t *v)
{
    uint32_t n;

    for (n = 0u; n < sizeof(v->zoom); n++) ((uint8_t *)v->zoom)[n] = 0u;
    v->mode = VIEW_RAW;
    demod_chain_init(&v->chain, NCO_INC, BIT_INC);
    capture_init(&v->cap);
}

void viewer_set_mode(viewer_t *v, view_mode_t mode)
{
    v->mode = (mode < VIEW_COUNT) ? mode : VIEW_RAW;
}

int viewer_key(viewer_t *v, key_action_t a)
{
    zoom_t *z = &v->zoom[v->mode];
    uint16_t n = view_points(v->mode);

    switch (a) {
    case KEY_NEXT:
        v->mode = (view_mode_t)((v->mode + 1u) % VIEW_COUNT);
        return 1;
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

int viewer_done(const viewer_t *v)
{
    return capture_done(&v->cap);
}

void viewer_process_block(viewer_t *v, const int16_t *iq, uint32_t n_samples)
{
    uint32_t k;

    if (capture_done(&v->cap)) return;

    for (k = 0; k < n_samples; k++) {
        demod_sample_t s;

        demod_chain_step(&v->chain, iq[2u * k], iq[2u * k + 1u], &s);
        capture_sample(&v->cap, &s);
    }
    capture_block(&v->cap, iq, n_samples);
}

static void draw_frame(tft_t *tft, view_mode_t m, const zoom_t *z)
{
    char buf[8];
    char *p;

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 6, 6, view_names[m], TFT_WHITE, TFT_BLACK, 2);

    if (z->level) {
        buf[0] = 'X';
        plot_u32_to_str(&buf[1], 1u << z->level);
        tft_draw_text(tft, 150, 6, buf, TFT_YELLOW, TFT_BLACK, 2);
    }

    p = plot_u32_to_str(buf, m + 1u);
    *p++ = '/';
    plot_u32_to_str(p, VIEW_COUNT);
    tft_draw_text(tft, (uint16_t)(tft->w - 6u - plot_text_w(buf)), 4, buf, TFT_YELLOW, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(tft->w - 6u - 72u), 15, "K1>  K2 ZOOM", TFT_GRAY, TFT_BLACK, 1);
}

static void draw_capture_progress(tft_t *tft, const capture_t *c)
{
    uint16_t bw = (uint16_t)(tft->w - 40u);
    uint32_t done = capture_progress(c, bw - 4u);

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 20, 80, "CAPTURE", TFT_WHITE, TFT_BLACK, 2);
    tft_draw_rect(tft, 20, 110, bw, 16, TFT_GRAY);
    tft_fill_rect(tft, 22, 112, (uint16_t)done, 12, TFT_GREEN);
}

void viewer_draw(viewer_t *v, tft_t *tft)
{
    const zoom_t *z = &v->zoom[v->mode];

    if (!capture_done(&v->cap)) {
        draw_capture_progress(tft, &v->cap);
        return;
    }

    draw_frame(tft, v->mode, z);

    switch (v->mode) {
    case VIEW_RAW:       view_raw(tft, &v->cap, z); break;
    case VIEW_BITS:      view_bits(tft, &v->cap, z); break;
    case VIEW_FFT:       view_fft(tft, &v->cap, z); break;
    case VIEW_WATERFALL: view_waterfall(tft, &v->cap, z); break;
    default: break;
    }
}
