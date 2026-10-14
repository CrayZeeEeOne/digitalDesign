#include "app/capture.h"
#include "config.h"
#include "dsp/dsp_math.h"

#define CONS_EVERY (CFG_CAPTURE_SAMPLES / DECIM_R / CAP_CONST_POINTS)

static void env_put(int16_t *lo, int16_t *hi, int16_t x)
{
    if (x < *lo) *lo = x;
    if (x > *hi) *hi = x;
}

void capture_init(capture_t *c)
{
    uint32_t n;
    int i, ch;

    for (n = 0u; n < sizeof(*c); n++) ((uint8_t *)c)[n] = 0u;

    for (i = 0; i < CAP_COLS; i++) {
        for (ch = 0; ch < CAP_CH_COUNT; ch++) {
            c->col[i].lo[ch] = 32767;
            c->col[i].hi[ch] = -32768;
        }
        c->col[i].dphi_lo = 32767;
        c->col[i].dphi_hi = -32768;
    }
    c->col_edge = CFG_CAPTURE_SAMPLES / CAP_COLS;
}

cap_col_t *capture_slot(capture_t *c)
{
    cap_col_t *col = 0;

    if (!c->done && c->sample_count >= CFG_WARMUP_SAMPLES) {
        uint32_t pos = c->sample_count - CFG_WARMUP_SAMPLES;

        if (pos >= CFG_CAPTURE_SAMPLES) {
            c->done = 1u;
        } else {
            while (pos >= c->col_edge) {
                c->col_idx++;
                c->col_edge = ((uint32_t)(c->col_idx + 1u) * CFG_CAPTURE_SAMPLES) / CAP_COLS;
            }
            col = &c->col[c->col_idx];
        }
    }
    c->sample_count++;
    return col;
}

void capture_put(capture_t *c, cap_col_t *col, const demod_sample_t *s)
{
    uint16_t p;

    if (!col) return;

    env_put(&col->lo[CAP_IN_I], &col->hi[CAP_IN_I], s->i);
    env_put(&col->lo[CAP_IN_Q], &col->hi[CAP_IN_Q], s->q);
    env_put(&col->lo[CAP_MIX_I], &col->hi[CAP_MIX_I], s->mi);
    env_put(&col->lo[CAP_MIX_Q], &col->hi[CAP_MIX_Q], s->mq);

    if (!s->dec_valid) return;

    if (s->burst_rise) c->burst_total++;

    p = clamp_u16(s->pavg);
    env_put(&col->lo[CAP_DEC_I], &col->hi[CAP_DEC_I], s->di);
    env_put(&col->lo[CAP_DEC_Q], &col->hi[CAP_DEC_Q], s->dq);
    env_put(&col->dphi_lo, &col->dphi_hi, (int16_t)s->dphi);
    col->favg = s->favg;
    col->dev = s->dev;
    if (p > col->pavg) col->pavg = p;
    col->noise = clamp_u16(s->noise);
    col->flags |= s->flags;

    if (c->cons_n < CAP_CONST_POINTS && (s->dec_count % CONS_EVERY) == 0u) {
        c->cons_i[c->cons_n] = s->di;
        c->cons_q[c->cons_n] = s->dq;
        c->cons_n++;
    }
}

uint32_t capture_progress(const capture_t *c, uint32_t total)
{
    return (c->sample_count * total) / (CFG_WARMUP_SAMPLES + CFG_CAPTURE_SAMPLES);
}
