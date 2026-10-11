#ifndef GRAPH_VIEWER_H
#define GRAPH_VIEWER_H

#include <stdint.h>
#include "tft.h"

typedef enum {
    VIEW_INPUT_IQ = 0,
    VIEW_MIXER_IQ,
    VIEW_CIC_IQ,
    VIEW_DPHI_POWER,
    VIEW_SPECTROGRAM,
    VIEW_WATERFALL,
    VIEW_CONSTELLATION,
    VIEW_DECODER,
    VIEW_COUNT
} view_mode_t;

typedef struct {
    uint32_t sample_rate_hz;
    uint32_t center_freq_hz;
    uint32_t channel_freq_hz;
    uint32_t bitrate;
} viewer_cfg_t;

typedef struct {
    viewer_cfg_t cfg;
    view_mode_t mode;

    uint16_t nco_phase;
    uint16_t nco_inc;

    int32_t i1, i2, i3;
    int32_t q1, q2, q3;
    int32_t ci0, ci1, ci2;
    int32_t cq0, cq1, cq2;
    uint8_t decim_ctr;

    int16_t prev_i;
    int16_t prev_q;
    int16_t favg;
    uint32_t pavg;
    uint32_t noise;
    uint8_t burst;
    uint8_t synced;
    uint8_t preamble;
    uint8_t pkt_active;

    uint32_t sample_count;
    uint32_t dec_count;
    uint32_t burst_count;

    int16_t in_i[240], in_q[240];
    int16_t mix_i[240], mix_q[240];
    int16_t dec_i[240], dec_q[240];
    int16_t dphi[240];
    uint16_t pwr[240], thr[240];
    uint8_t burst_tl[240], sync_tl[240], pre_tl[240], pkt_tl[240];

    int16_t cons_i[192], cons_q[192];
    uint16_t cons_wr;

    int16_t spec_hist[64];
    uint8_t spec_col[112];
    uint16_t spec_ctr;
    uint8_t spectrogram[112][112];
    uint8_t waterfall[112][112];
} graph_viewer_t;

void graph_viewer_init(graph_viewer_t *v, const viewer_cfg_t *cfg);
void graph_viewer_set_mode(graph_viewer_t *v, view_mode_t mode);
void graph_viewer_next(graph_viewer_t *v);
void graph_viewer_prev(graph_viewer_t *v);
void graph_viewer_process_block(graph_viewer_t *v, const int16_t *iq, uint32_t n_samples);
void graph_viewer_draw(graph_viewer_t *v, tft_t *tft);

#endif
