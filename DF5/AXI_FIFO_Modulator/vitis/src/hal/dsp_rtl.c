#include "hal/dsp_rtl.h"
#include "xil_io.h"
#include "config.h"

/* demodulator bank (rtl_demod map) */
#define DM_CTRL        0x000u    /* [0] enable [1] soft reset [2] clear stats [3] ack result */
#define DM_STATUS      0x004u    /* [3] result valid */
#define DM_NCO_INC     0x008u
#define DM_DECIM       0x00Cu
#define DM_BIT_INC     0x014u
#define DM_SYNC_WORD   0x018u
#define DM_PKT_LEN     0x01Cu
#define DM_CRC_OK_CNT  0x050u
#define DM_RES_FLAGS   0x060u    /* [3] crc ok [7:6] kind (0 = packet) */
#define DM_RES_BYTES   0x080u
#define DM_PKT_MEM     0x100u
#define DM_ID          0x0FCu

/* source / generator */
#define SRC_CTRL       0x200u    /* [0] 1 = generator [1] generator on */
#define GEN_RATE       0x204u
#define GEN_FOFS       0x208u
#define GEN_DEV        0x20Cu
#define GEN_BIT_INC    0x210u
#define GEN_LEVEL      0x214u
#define GEN_PERIOD     0x218u
#define GEN_GAP        0x21Cu
#define GEN_PKTS       0x220u
#define DSP_ID         0x2FCu

/* capture */
#define CAP_CTRL       0x300u    /* [0] arm [1] abort */
#define CAP_STATUS     0x304u    /* [2:0] state */
#define CAP_WARMUP     0x308u
#define CAP_LEN        0x30Cu
#define CAP_COL        0x310u
#define CAP_MODE       0x314u    /* [4:0] waterfall shift [8] no wait */
#define CAP_POS        0x318u
#define CAP_PKT        0x320u    /* + 16 * p: START, END, FIRST_BIT, NBITS */
#define CAP_BITS       0x400u    /* + 64 * p */
#define CAP_RAW        0x800u
#define SPEC_CTRL      0x340u    /* [0] live */
#define SPEC_ROWS      0x344u
#define SPEC_BIN0_REG  0x348u    /* first FFT bin of the 128 shown */
#define CAP_WF         0x8000u   /* ring: row r at 0x8000 + 128 * (r % 256) */
#define WF_RING        256u

#define ID_DEMOD       0x44534D01u
#define ID_DSP         0x44535001u

/*
 * Register values from config.h, as compile-time constants (64-bit math is
 * folded by the compiler, nothing is divided at run time).
 */
#define FS             ((int64_t)CFG_SAMPLE_RATE_HZ)
#define CH_OFS_HZ      ((int64_t)CFG_CHANNEL_FREQ_HZ - (int64_t)CFG_CENTER_FREQ_HZ)
#define RATIO32(num, den) ((uint32_t)((((int64_t)(num) << 32) + (den) / 2) / (den)))

#define DEMOD_DECIM    16u
#define DEMOD_CIC_SH   12u       /* 3 * log2(16) */
#define DEMOD_NCO_INC  RATIO32(-CH_OFS_HZ, FS)                        /* channel -> 0 Hz */
#define DEMOD_BIT_INC  ((uint32_t)(((int64_t)CFG_BITRATE * DEMOD_DECIM * 65536 + FS / 2) / FS))

#define GEN_CFO_HZ     3000      /* carrier error of the test signal, as in sim.iq */
#define GEN_RATE_VAL   RATIO32(FS, (int64_t)CFG_ACLK_HZ)               /* real time */
#define GEN_FOFS_VAL   ((uint32_t)(((CH_OFS_HZ + GEN_CFO_HZ) * 4294967296LL - FS / 2) / FS))
#define GEN_DEV_VAL    RATIO32(CFG_DEVIATION_HZ, FS)
#define GEN_BIT_VAL    RATIO32(CFG_BITRATE, FS)
#define GEN_AMP        6000u     /* LSB */
#define GEN_NOISE      1470u     /* 424 LSB rms: SNR 20 dB */
#define GEN_PERIOD_VAL 156250u   /* one packet (108750 samples) every 34.7 ms */
#define GEN_GAP_VAL    47500u

static inline uint32_t rd(const dsp_rtl_t *d, uint32_t r) { return Xil_In32(d->base + r); }
static inline void wr(const dsp_rtl_t *d, uint32_t r, uint32_t v) { Xil_Out32(d->base + r, v); }

int dsp_rtl_init(dsp_rtl_t *d, uint32_t base)
{
    d->base = base;
    if (rd(d, DM_ID) != ID_DEMOD || rd(d, DSP_ID) != ID_DSP) return -1;

    wr(d, DM_CTRL, 0x2u);                                   /* soft reset, disabled */
    wr(d, DM_NCO_INC, DEMOD_NCO_INC);
    wr(d, DM_DECIM, (DEMOD_CIC_SH << 8) | DEMOD_DECIM);
    wr(d, DM_BIT_INC, DEMOD_BIT_INC);
    wr(d, DM_SYNC_WORD, CFG_SYNC_WORD);
    wr(d, DM_PKT_LEN, CFG_PKT_BYTES);

    wr(d, GEN_RATE, GEN_RATE_VAL);
    wr(d, GEN_FOFS, GEN_FOFS_VAL);
    wr(d, GEN_DEV, GEN_DEV_VAL);
    wr(d, GEN_BIT_INC, GEN_BIT_VAL);
    wr(d, GEN_LEVEL, (GEN_NOISE << 16) | GEN_AMP);
    wr(d, GEN_PERIOD, GEN_PERIOD_VAL);
    wr(d, GEN_GAP, GEN_GAP_VAL);

    wr(d, CAP_WARMUP, CFG_WARMUP_SAMPLES);
    wr(d, CAP_LEN, CFG_CAPTURE_SAMPLES);
    wr(d, SPEC_BIN0_REG, SPEC_BIN0);                        /* spectrum window around the channel */
    wr(d, CAP_COL, ((CFG_CAPTURE_SAMPLES % CAP_RAW_COLS) << 16) | (CFG_CAPTURE_SAMPLES / CAP_RAW_COLS));
    return 0;
}

void dsp_rtl_set_source(dsp_rtl_t *d, dsp_src_t src)
{
    wr(d, SRC_CTRL, src == DSP_SRC_GEN ? 0x3u : 0x0u);
}

void dsp_rtl_start(dsp_rtl_t *d, int nowait)
{
    d->ndec = 0u;
    wr(d, SPEC_CTRL, 0u);                                   /* spectrum of the capture only */
    wr(d, CAP_WARMUP, CFG_WARMUP_SAMPLES);
    wr(d, DM_CTRL, 0x6u);                                   /* soft reset + clear stats */
    wr(d, CAP_MODE, (nowait ? 0x100u : 0u) | SPEC_WF_SHIFT);
    wr(d, CAP_CTRL, 0x1u);                                  /* arm */
    wr(d, DM_CTRL, 0x1u);                                   /* enable: samples flow */
}

void dsp_rtl_live_start(dsp_rtl_t *d)
{
    d->ndec = 0u;
    wr(d, SRC_CTRL, 0x3u);                                  /* generator, on */
    wr(d, DM_CTRL, 0x6u);                                   /* demodulator from scratch */
    wr(d, DM_CTRL, 0x1u);
    wr(d, CAP_WARMUP, 1u);                                  /* the demodulator keeps running */
    wr(d, CAP_MODE, 0x100u | CFG_LIVE_WF_SHIFT);            /* no trigger wait */
    wr(d, SPEC_CTRL, 1u);                                   /* spectrum of every block */
    wr(d, CAP_CTRL, 0x1u);
}

void dsp_rtl_rearm(dsp_rtl_t *d)
{
    d->ndec = 0u;
    wr(d, CAP_CTRL, 0x1u);
}

void dsp_rtl_live_spectrum(dsp_rtl_t *d, int on)
{
    wr(d, SPEC_CTRL, on ? 1u : 0u);
}

uint32_t dsp_rtl_spec_rows(const dsp_rtl_t *d)
{
    return rd(d, SPEC_ROWS);
}

int dsp_rtl_poll(dsp_rtl_t *d)
{
    int state = (int)(rd(d, CAP_STATUS) & 7u);

    if (rd(d, DM_STATUS) & 0x8u) {                          /* a result is latched */
        uint32_t flags = rd(d, DM_RES_FLAGS);

        if (((flags >> 6) & 3u) == 0u && state == DSP_CAP_RECORD && d->ndec < CAP_PKTS) {
            cap_dec_t *p = &d->dec[d->ndec++];
            uint32_t n = rd(d, DM_RES_BYTES) & 0xFFu, k;

            if (n > CAP_DEC_BYTES) n = CAP_DEC_BYTES;
            p->valid = 1u;
            p->crc_ok = (uint8_t)((flags >> 3) & 1u);
            p->nbytes = (uint8_t)n;
            for (k = 0u; k < n; k += 4u) {
                uint32_t w = rd(d, DM_PKT_MEM + k);
                uint32_t b;
                for (b = 0u; b < 4u && k + b < n; b++) p->bytes[k + b] = (uint8_t)(w >> (8u * b));
            }
        }
        wr(d, DM_CTRL, 0x9u);                               /* enable + ack */
    }
    return state;
}

uint32_t dsp_rtl_capture_pos(const dsp_rtl_t *d)
{
    return rd(d, CAP_POS);
}

/* n 32-bit words from the dsp registers into memory, byte k of the area in
   bits [8*(k%4)+:8] of word k/4. Stored byte by byte: dst need not be aligned. */
static void copy_words(const dsp_rtl_t *d, uint32_t reg, void *dst, uint32_t n)
{
    uint8_t *p = (uint8_t *)dst;
    while (n--) {
        uint32_t w = rd(d, reg);
        p[0] = (uint8_t)w;
        p[1] = (uint8_t)(w >> 8);
        p[2] = (uint8_t)(w >> 16);
        p[3] = (uint8_t)(w >> 24);
        p += 4;
        reg += 4u;
    }
}

void dsp_rtl_read_row(const dsp_rtl_t *d, uint32_t row, uint8_t *dst)
{
    copy_words(d, CAP_WF + 128u * (row % WF_RING), dst, SPEC_BINS / 4u);
}

void dsp_rtl_read_capture(const dsp_rtl_t *d, cap_data_t *c, int spectra)
{
    uint32_t p;

    c->ndec = d->ndec;
    for (p = 0u; p < d->ndec; p++) c->dec[p] = d->dec[p];

    copy_words(d, CAP_RAW, c->raw, CAP_RAW_COLS);
    c->npkt = (uint8_t)((rd(d, CAP_STATUS) >> 4) & 3u);
    for (p = 0u; p < CAP_PKTS; p++) {
        cap_pkt_t *k = &c->pkt[p];
        uint32_t r = CAP_PKT + 16u * p;
        k->start = rd(d, r);
        k->end = rd(d, r + 4u);
        k->first_bit = rd(d, r + 8u);
        k->nbits = (uint16_t)rd(d, r + 12u);
        copy_words(d, CAP_BITS + 64u * p, k->bits, CAP_PKT_BITS / 32u);
    }
    if (!spectra) return;
    copy_words(d, CAP_WF, c->wf, CAP_WF_ROWS * SPEC_BINS / 4u);

    /* spectrum of the capture = max hold over the waterfall rows */
    for (p = 0u; p < SPEC_BINS; p++) {
        uint8_t v = 0u;
        uint32_t r;
        for (r = 0u; r < CAP_WF_ROWS; r++)
            if (c->wf[r][p] > v) v = c->wf[r][p];
        c->fft[p] = v;
    }
}

uint32_t dsp_rtl_gen_packets(const dsp_rtl_t *d)
{
    return rd(d, GEN_PKTS);
}

uint32_t dsp_rtl_crc_ok_count(const dsp_rtl_t *d)
{
    return rd(d, DM_CRC_OK_CNT);
}
