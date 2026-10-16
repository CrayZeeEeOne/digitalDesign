#include "app/capture.h"

enum { CAP_WARMUP = 0, CAP_WAIT, CAP_RECORD, CAP_DONE };

#define WF_BLOCKS_PER_ROW (CFG_CAPTURE_SAMPLES / CFG_IQ_BLOCK / CAP_WF_ROWS)

static int8_t raw_q(int16_t x)
{
    int16_t v = (int16_t)(x >> CAP_RAW_SHIFT);
    return (int8_t)(v > 127 ? 127 : (v < -127 ? -127 : v));
}

static void raw_put(cap_raw_t *r, int16_t i16, int16_t q16)
{
    int8_t i = raw_q(i16), q = raw_q(q16);

    if (i < r->i_lo) r->i_lo = i;
    if (i > r->i_hi) r->i_hi = i;
    if (q < r->q_lo) r->q_lo = q;
    if (q > r->q_hi) r->q_hi = q;
}

void capture_init(capture_t *c)
{
    uint32_t n;
    int i;

    for (n = 0u; n < sizeof(*c); n++) ((uint8_t *)c)[n] = 0u;
    for (i = 0; i < CAP_RAW_COLS; i++) {
        c->raw[i].i_lo = c->raw[i].q_lo = 127;
        c->raw[i].i_hi = c->raw[i].q_hi = -127;
    }
    c->raw_edge = CFG_CAPTURE_SAMPLES / CAP_RAW_COLS;
    c->state = CAP_WARMUP;
}

static void end_packet(capture_t *c)
{
    c->pkt[c->npkt].end = c->pos;
    c->npkt++;
    c->in_pkt = 0u;
}

static void record(capture_t *c, const demod_sample_t *s)
{
    cap_pkt_t *p = &c->pkt[c->npkt];

    while (c->pos >= c->raw_edge) {
        c->raw_idx++;
        c->raw_edge = ((uint32_t)(c->raw_idx + 1u) * CFG_CAPTURE_SAMPLES) / CAP_RAW_COLS;
    }
    raw_put(&c->raw[c->raw_idx], s->i, s->q);
    c->blk_rec = 1u;

    if (s->dec_valid) {
        if (s->burst_rise && c->npkt < CAP_PKTS) {
            p->start = c->pos;
            p->nbits = 0u;
            c->in_pkt = 1u;
        }
        if (c->in_pkt && s->bit_valid && p->nbits < CAP_PKT_BITS) {
            if (p->nbits == 0u) p->first_bit = c->pos;
            if (s->bit) p->bits[p->nbits >> 3] |= (uint8_t)(0x80u >> (p->nbits & 7u));
            p->nbits++;
        }
        if (s->burst_fall && c->in_pkt) end_packet(c);
    }

    if (++c->pos >= CFG_CAPTURE_SAMPLES) {
        if (c->in_pkt) end_packet(c);
        c->state = CAP_DONE;
    }
}

void capture_sample(capture_t *c, const demod_sample_t *s)
{
    switch (c->state) {
    case CAP_WARMUP:
        if (++c->count >= CFG_WARMUP_SAMPLES) {
            c->state = CAP_WAIT;
            c->count = 0u;
        }
        break;
    case CAP_WAIT:
        /* Start in a gap, right after a packet ends (or give up waiting). */
        if ((s->dec_valid && s->burst_fall) || ++c->count >= CFG_CAPTURE_SAMPLES)
            c->state = CAP_RECORD;
        break;
    case CAP_RECORD:
        record(c, s);
        break;
    default:
        break;
    }
}

/*
 * Spectrum of the capture = max hold over the waterfall rows: packets are short
 * bursts, an average over the whole capture would drag their level down by the gaps.
 */
static void finish_spectra(capture_t *c)
{
    uint16_t b, r;

    for (b = 0u; b < SPEC_BINS; b++) {
        uint8_t m = 0u;
        for (r = 0u; r < c->wf_row; r++)
            if (c->wf[r][b] > m) m = c->wf[r][b];
        c->fft[b] = m;
    }
}

void capture_block(capture_t *c, const int16_t *iq, uint32_t n_samples)
{
    uint16_t b;

    if (!c->blk_rec || n_samples < SPEC_FFT_N) return;
    c->blk_rec = 0u;

    spectrum_mag(iq, c->fft_re, c->fft_im, c->mag);
    for (b = 0u; b < SPEC_BINS; b++) c->wf_acc[b] += c->mag[b];

    if (++c->wf_blocks >= WF_BLOCKS_PER_ROW) {
        if (c->wf_row < CAP_WF_ROWS) {
            for (b = 0u; b < SPEC_BINS; b++)
                c->wf[c->wf_row][b] = spec_log(c->wf_acc[b] / c->wf_blocks);
            c->wf_row++;
        }
        for (b = 0u; b < SPEC_BINS; b++) c->wf_acc[b] = 0u;
        c->wf_blocks = 0u;
    }

    if (c->state == CAP_DONE) finish_spectra(c);
}

int capture_done(const capture_t *c)
{
    return c->state == CAP_DONE;
}

uint32_t capture_progress(const capture_t *c, uint32_t total)
{
    if (c->state == CAP_DONE) return total;
    if (c->state != CAP_RECORD) return 0u;
    return (c->pos / 64u) * total / (CFG_CAPTURE_SAMPLES / 64u);
}
