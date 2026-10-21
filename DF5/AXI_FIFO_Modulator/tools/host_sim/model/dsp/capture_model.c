#include "dsp/capture_model.h"

enum { CAP_WARMUP = 0, CAP_WAIT, CAP_RECORD, CAP_DONE };

#define WF_BLOCKS_PER_ROW (1u << SPEC_WF_SHIFT)

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

void capture_model_init(capture_model_t *m, uint16_t nco_inc, uint16_t bit_inc)
{
    uint32_t n;
    int i;

    for (n = 0u; n < sizeof(*m); n++) ((uint8_t *)m)[n] = 0u;
    demod_chain_init(&m->chain, nco_inc, bit_inc);
    for (i = 0; i < CAP_RAW_COLS; i++) {
        m->d.raw[i].i_lo = m->d.raw[i].q_lo = 127;
        m->d.raw[i].i_hi = m->d.raw[i].q_hi = -127;
    }
    m->raw_edge = CFG_CAPTURE_SAMPLES / CAP_RAW_COLS;
    m->state = CAP_WARMUP;
}

static void end_packet(capture_model_t *m)
{
    m->d.pkt[m->d.npkt].end = m->pos;
    m->d.npkt++;
    m->in_pkt = 0u;
}

static void record(capture_model_t *m, const demod_sample_t *s)
{
    cap_pkt_t *p = &m->d.pkt[m->d.npkt];

    while (m->pos >= m->raw_edge) {
        m->raw_idx++;
        m->raw_edge = ((uint32_t)(m->raw_idx + 1u) * CFG_CAPTURE_SAMPLES) / CAP_RAW_COLS;
    }
    raw_put(&m->d.raw[m->raw_idx], s->i, s->q);
    m->blk_rec = 1u;

    if (s->dec_valid) {
        if (s->burst_rise && m->d.npkt < CAP_PKTS) {
            p->start = m->pos;
            p->nbits = 0u;
            m->in_pkt = 1u;
        }
        if (m->in_pkt && s->bit_valid && p->nbits < CAP_PKT_BITS) {
            if (p->nbits == 0u) p->first_bit = m->pos;
            if (s->bit) p->bits[p->nbits >> 3] |= (uint8_t)(0x80u >> (p->nbits & 7u));
            p->nbits++;
        }
        if (s->burst_fall && m->in_pkt) end_packet(m);
    }

    if (++m->pos >= CFG_CAPTURE_SAMPLES) {
        if (m->in_pkt) end_packet(m);
        m->state = CAP_DONE;
    }
}

static void capture_sample(capture_model_t *m, const demod_sample_t *s)
{
    switch (m->state) {
    case CAP_WARMUP:
        if (++m->count >= CFG_WARMUP_SAMPLES) {
            m->state = CAP_WAIT;
            m->count = 0u;
        }
        break;
    case CAP_WAIT:
        /* Start in a gap, right after a packet ends (or give up waiting). */
        if ((s->dec_valid && s->burst_fall) || ++m->count >= CFG_CAPTURE_SAMPLES)
            m->state = CAP_RECORD;
        break;
    case CAP_RECORD:
        record(m, s);
        break;
    default:
        break;
    }
}

/*
 * Spectrum of the capture = max hold over the waterfall rows: packets are short
 * bursts, an average over the whole capture would drag their level down by the gaps.
 */
static void finish_spectra(capture_model_t *m)
{
    uint16_t b, r;

    for (b = 0u; b < SPEC_BINS; b++) {
        uint8_t v = 0u;
        for (r = 0u; r < m->wf_row; r++)
            if (m->d.wf[r][b] > v) v = m->d.wf[r][b];
        m->d.fft[b] = v;
    }
}

static void capture_spectrum(capture_model_t *m, const int16_t *iq, uint32_t n_samples)
{
    uint16_t b;

    if (!m->blk_rec || n_samples < SPEC_FFT_N) return;
    m->blk_rec = 0u;

    spectrum_mag(iq, m->fft_re, m->fft_im, m->mag);
    for (b = 0u; b < SPEC_BINS; b++) m->wf_acc[b] += m->mag[b];

    if (++m->wf_blocks >= WF_BLOCKS_PER_ROW) {
        if (m->wf_row < CAP_WF_ROWS) {
            for (b = 0u; b < SPEC_BINS; b++)
                m->d.wf[m->wf_row][b] = spec_log(m->wf_acc[b] / m->wf_blocks);
            m->wf_row++;
        }
        for (b = 0u; b < SPEC_BINS; b++) m->wf_acc[b] = 0u;
        m->wf_blocks = 0u;
    }

    if (m->state == CAP_DONE) finish_spectra(m);
}

void capture_model_block(capture_model_t *m, const int16_t *iq, uint32_t n_samples)
{
    uint32_t k;

    if (capture_model_done(m)) return;

    for (k = 0; k < n_samples; k++) {
        demod_sample_t s;

        demod_chain_step(&m->chain, iq[2u * k], iq[2u * k + 1u], &s);
        capture_sample(m, &s);
    }
    capture_spectrum(m, iq, n_samples);
}

int capture_model_done(const capture_model_t *m)
{
    return m->state == CAP_DONE;
}
