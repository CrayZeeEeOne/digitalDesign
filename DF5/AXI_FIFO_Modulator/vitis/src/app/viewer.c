#include "app/viewer.h"
#include "config.h"
#include "gfx/plot.h"
#include "app/view_capture.h"

/* NCO step that moves the channel to 0 Hz (2^16 = Fs). */
#define NCO_INC ((uint16_t)((65536u * (CFG_CENTER_FREQ_HZ - CFG_CHANNEL_FREQ_HZ) / CFG_SAMPLE_RATE_HZ) & 0xFFFFu))

void viewer_init(viewer_t *v)
{
    uint16_t inc = NCO_INC;

    if (inc == 0u) inc = 911u;

    v->mode = VIEW_INPUT_IQ;
    demod_chain_init(&v->chain, inc);
    capture_init(&v->cap);
    live_spectrum_stop(&v->live);
}

void viewer_set_mode(viewer_t *v, view_mode_t mode)
{
    if (mode >= VIEW_COUNT) mode = VIEW_INPUT_IQ;
    v->mode = mode;
}

void viewer_next(viewer_t *v)
{
    v->mode = (view_mode_t)((v->mode + 1u) % VIEW_COUNT);
}

void viewer_prev(viewer_t *v)
{
    v->mode = (view_mode_t)((v->mode + VIEW_COUNT - 1u) % VIEW_COUNT);
}

int viewer_done(const viewer_t *v)
{
    return v->cap.done;
}

int viewer_busy(const viewer_t *v)
{
    return !v->cap.done || live_spectrum_active(&v->live);
}

void viewer_process_block(viewer_t *v, const int16_t *iq, uint32_t n_samples)
{
    uint32_t k;

    if (!viewer_busy(v)) return;

    for (k = 0; k < n_samples; k++) {
        cap_col_t *col = capture_slot(&v->cap);
        demod_sample_t s;

        demod_chain_step(&v->chain, iq[2u * k], iq[2u * k + 1u], &s);
        capture_put(&v->cap, col, &s);
        if (s.dec_valid && s.burst_rise)
            live_spectrum_on_burst(&v->live);
    }

    live_spectrum_feed(&v->live, iq, n_samples);
}

static void draw_frame(tft_t *tft, const char *title, uint8_t page)
{
    char buf[8];
    char *p;

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 6, 6, title, TFT_WHITE, TFT_BLACK, 2);

    p = plot_u32_to_str(buf, page + 1u);
    *p++ = '/';
    plot_u32_to_str(p, VIEW_COUNT);
    tft_draw_text(tft, (uint16_t)(tft->w - 6u - plot_text_w(buf)), 4, buf, TFT_YELLOW, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(tft->w - 48u), 15, "K1> K2<", TFT_GRAY, TFT_BLACK, 1);
}

static void draw_capture_progress(tft_t *tft, const capture_t *c)
{
    uint16_t bw = (uint16_t)(tft->w - 40u);
    uint32_t done = capture_progress(c, bw);

    tft_clear(tft, TFT_BLACK);
    tft_draw_rect(tft, 0, 0, tft->w, tft->h, TFT_GREEN);
    tft_draw_text(tft, 20, 80, "CAPTURE", TFT_WHITE, TFT_BLACK, 2);
    tft_draw_rect(tft, 20, 110, bw, 16, TFT_GRAY);
    if (done > (uint32_t)(bw - 4u)) done = (uint32_t)(bw - 4u);
    tft_fill_rect(tft, 22, 112, (uint16_t)done, 12, TFT_GREEN);
}

void viewer_draw(viewer_t *v, tft_t *tft)
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

    live_spectrum_stop(&v->live);

    if (!v->cap.done) {
        draw_capture_progress(tft, &v->cap);
        return;
    }

    draw_frame(tft, names[v->mode], (uint8_t)v->mode);

    switch (v->mode) {
    case VIEW_INPUT_IQ:       view_iq_pair(tft, &v->cap, CAP_IN_I, 3000, iq_names); break;
    case VIEW_PKT0_SPECTRO:   live_spectrum_arm(&v->live, tft, 1, 0u); break;
    case VIEW_PKT0_WATERFALL: live_spectrum_arm(&v->live, tft, 0, 0u); break;
    case VIEW_PKT1_SPECTRO:   live_spectrum_arm(&v->live, tft, 1, 1u); break;
    case VIEW_PKT1_WATERFALL: live_spectrum_arm(&v->live, tft, 0, 1u); break;
    case VIEW_MIXER_IQ:       view_iq_pair(tft, &v->cap, CAP_MIX_I, 3000, mix_names); break;
    case VIEW_CIC_IQ:         view_iq_pair(tft, &v->cap, CAP_DEC_I, 1800, dec_names); break;
    case VIEW_CONSTELLATION:  view_constellation(tft, &v->cap); break;
    case VIEW_DPHI:           view_dphi(tft, &v->cap); break;
    case VIEW_POWER:          view_power(tft, &v->cap); break;
    case VIEW_BITDEC:         view_bit_decoder(tft, &v->cap); break;
    case VIEW_DECODER:        view_decoder_timeline(tft, &v->cap); break;
    default: break;
    }
}
