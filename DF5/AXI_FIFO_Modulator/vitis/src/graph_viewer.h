#ifndef GRAPH_VIEWER_H
#define GRAPH_VIEWER_H

#include <stdint.h>
#include "tft.h"

/* Same list and order as sim_data/rtl_demod_plots.html. */
typedef enum {
    VIEW_INPUT_IQ = 0,
    VIEW_PKT0_SPECTRO,
    VIEW_PKT0_WATERFALL,
    VIEW_PKT1_SPECTRO,
    VIEW_PKT1_WATERFALL,
    VIEW_MIXER_IQ,
    VIEW_CIC_IQ,
    VIEW_CONSTELLATION,
    VIEW_DPHI,
    VIEW_POWER,
    VIEW_BITDEC,
    VIEW_DECODER,
    VIEW_COUNT
} view_mode_t;

typedef struct {
    uint32_t sample_rate_hz;
    uint32_t center_freq_hz;
    uint32_t channel_freq_hz;
    uint32_t bitrate;
} viewer_cfg_t;

/*
 * The viewer records one fixed capture and then freezes, so every plot shows
 * the whole capture at once (like the HTML report) instead of a scrolling window.
 * Each capture column keeps min/max (or last value) of
 * GV_CAPTURE_SAMPLES / GV_COLS input samples.
 */
#define GV_WARMUP_SAMPLES  16384u    /* estimators settle, not recorded */
#define GV_CAPTURE_SAMPLES 163840u   /* ~36 ms at 4.5 MS/s, ~2 packet cycles */

enum {
    GV_COLS          = 160,
    GV_CONST_POINTS  = 64,
    GV_FFT_N         = 256,  /* FFT size: fs/256 = ~17.6 kHz per bin, one FFT per block */
    GV_SPEC_BINS     = 64,   /* central bins shown: +-fs*32/256 = +-562 kHz */
    GV_SPEC_PRE      = 16,   /* columns kept before burst start */
    GV_WF_TRACES     = 24,   /* waterfall lines */
    GV_WF_EVERY      = 6,    /* columns averaged per waterfall line */
    GV_LIVE_TIMEOUT  = 1200  /* blocks to wait for a burst */
};

/* Channels of gv_col_t.lo/hi. */
enum { GV_IN_I = 0, GV_IN_Q, GV_MIX_I, GV_MIX_Q, GV_DEC_I, GV_DEC_Q, GV_CH_COUNT };

/* Bits of gv_col_t.flags. */
enum {
    GV_F_BURST = 1u << 0,
    GV_F_SYNC  = 1u << 1,
    GV_F_PRE   = 1u << 2,
    GV_F_PKT   = 1u << 3,
    GV_F_RES   = 1u << 4
};

typedef struct {
    int16_t lo[GV_CH_COUNT], hi[GV_CH_COUNT];
    int16_t dphi_lo, dphi_hi;
    int16_t favg, dev;
    uint16_t pavg, noise;      /* threshold is derived from noise */
    uint8_t flags;
} gv_col_t;

typedef struct {
    viewer_cfg_t cfg;
    view_mode_t mode;

    uint16_t nco_phase;
    uint16_t nco_inc;

    int32_t i_acc;
    int32_t q_acc;
    uint8_t decim_ctr;

    int16_t prev_i;
    int16_t prev_q;
    int16_t favg;
    int16_t dev;
    uint32_t pavg;
    uint32_t noise;
    uint8_t burst;
    uint8_t burst_hang;
    uint8_t pkt_active;
    uint8_t done;

    uint32_t sample_count;
    uint32_t dec_count;
    uint32_t burst_start;
    uint32_t burst_total;

    gv_col_t col[GV_COLS];
    uint16_t col_idx;
    uint32_t col_edge;

    int16_t cons_i[GV_CONST_POINTS], cons_q[GV_CONST_POINTS];
    uint16_t cons_n;

    /*
     * Spectrum views are too big to keep in BRAM at full screen resolution, so they
     * are drawn straight to the panel from new data: wait for a burst, then one
     * pixel column (or waterfall line) per FFT until the plot is full.
     * Spectrum bin 0 = lowest frequency, bin GV_SPEC_BINS/2 = center frequency.
     */
    tft_t *tft;
    uint8_t live;              /* LIVE_* state */
    uint8_t live_skip;         /* bursts to skip before the shown one (P1 = 1) */
    uint16_t live_x;           /* spectrum columns drawn so far */
    uint16_t live_wait;        /* blocks waited for a burst */
    uint8_t live_lo;           /* color/height scale floor = noise level */
    uint8_t spec_pre[GV_SPEC_PRE][GV_SPEC_BINS];
    uint8_t spec_wr;
    uint16_t wf_acc[GV_SPEC_BINS];
    int16_t fft_re[GV_FFT_N], fft_im[GV_FFT_N];
} graph_viewer_t;

void graph_viewer_init(graph_viewer_t *v, const viewer_cfg_t *cfg);
void graph_viewer_set_mode(graph_viewer_t *v, view_mode_t mode);
void graph_viewer_next(graph_viewer_t *v);
void graph_viewer_prev(graph_viewer_t *v);
void graph_viewer_process_block(graph_viewer_t *v, const int16_t *iq, uint32_t n_samples);
int  graph_viewer_done(const graph_viewer_t *v);
/* Nonzero while the viewer needs more input blocks (capture or live spectrum). */
int  graph_viewer_busy(const graph_viewer_t *v);
void graph_viewer_draw(graph_viewer_t *v, tft_t *tft);

#endif
