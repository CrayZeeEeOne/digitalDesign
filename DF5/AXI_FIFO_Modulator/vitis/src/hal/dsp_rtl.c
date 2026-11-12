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
#define DM_CRC_CFG     0x020u    /* [15:0] polynomial [31:16] start value */
#define DM_CRC_RES     0x024u    /* [15:0] residue [16] PN9 dewhitening */
#define DM_RES_FLAGS   0x060u    /* [3] crc ok [7:6] kind (0 = packet) */
#define DM_RES_BYTES   0x080u
#define DM_PKT_MEM     0x100u
#define DM_ID          0x0FCu

/* input, channel search */
#define DSP_CTRL       0x200u    /* [3:0] input shift [8] empty the delay line */
#define DSP_IN_COUNT   0x208u
#define DSP_ID         0x2FCu
#define HOP_CTRL       0x380u    /* [0] on [7:4] threshold shift [11:8] noise IIR [15:12] confirm [31:16] hold */
#define HOP_STATUS     0x384u    /* [11:8] channel of the last demodulator result */
#define HOP_DETS       0x388u
#define HOP_CHMAP      0x38Cu    /* [7:0] FFT bin [11:8] channel */
#define HOP_NCO        0x390u    /* + 4 * channel */
#define HOP_MIN        0x3CCu

/* capture, spectrum */
#define CAP_CTRL       0x300u    /* [0] arm [1] abort */
#define CAP_STATUS     0x304u    /* [2:0] state [5:4] packets */
#define CAP_WARMUP     0x308u
#define CAP_LEN        0x30Cu
#define CAP_COL        0x310u
#define CAP_MODE       0x314u    /* [4:0] waterfall shift [8] no wait [9] wait for dsp_hop */
#define CAP_PKT        0x320u    /* + 16 * p: START, END, FIRST_BIT, NBITS */
#define CAP_BITS       0x400u    /* + 64 * p */
#define CAP_RAW        0x800u
#define SPEC_CTRL      0x340u    /* [0] live */
#define SPEC_ROWS      0x344u
#define SPEC_BIN0_REG  0x348u
#define CAP_WF         0x8000u   /* ring: row r at 0x8000 + 128 * (r % 256) */
#define SPEC_LAST      0x0480u   /* the newest row, also while the ring is frozen */
#define WF_RING        256u

#define ID_DEMOD       0x44534D01u
#define ID_DSP         0x44535002u

/*
 * Register values from config.h, as compile-time constants (64-bit math is
 * folded by the compiler, nothing is divided at run time).
 */
#define FS             ((int64_t)CFG_SAMPLE_RATE_HZ)
#define DEMOD_DECIM    16u
#define DEMOD_CIC_SH   12u       /* 3 * log2(16) */
#define DEMOD_BIT_INC  ((uint32_t)(((int64_t)CFG_BITRATE * DEMOD_DECIM * 65536 + FS / 2) / FS))
#define CRC_START      0x1D0Fu   /* radio CRC16: poly 0x1021, start 0x1D0F, inverted -> residue 0x1D0F */

static const uint32_t hop_khz[CFG_HOP_N] = CFG_HOP_CHANNELS_KHZ;

static inline uint32_t rd(const dsp_rtl_t *d, uint32_t r) { return Xil_In32(d->base + r); }
static inline void wr(const dsp_rtl_t *d, uint32_t r, uint32_t v) { Xil_Out32(d->base + r, v); }

/* Offset of a channel from the LO in kHz. */
static int32_t ch_ofs_khz(uint32_t c)
{
    return (int32_t)hop_khz[c] - (int32_t)(CFG_CENTER_FREQ_HZ / 1000u);
}

/* round(x / y) for signed x, positive y */
static int32_t div_round(int32_t x, int32_t y)
{
    return (x >= 0) ? (x + y / 2) / y : -((-x + y / 2) / y);
}

int dsp_rtl_init(dsp_rtl_t *d, uint32_t base)
{
    uint32_t c, b;

    d->base = base;
    if (rd(d, DM_ID) != ID_DEMOD || rd(d, DSP_ID) != ID_DSP) return -1;

    wr(d, DM_CTRL, 0x2u);                                   /* soft reset, disabled */
    wr(d, DM_NCO_INC, 0u);
    wr(d, DM_DECIM, (DEMOD_CIC_SH << 8) | DEMOD_DECIM);
    wr(d, DM_BIT_INC, DEMOD_BIT_INC);
    wr(d, DM_SYNC_WORD, CFG_SYNC_WORD);
    wr(d, DM_PKT_LEN, CFG_PKT_BYTES);
    wr(d, DM_CRC_CFG, (CRC_START << 16) | 0x1021u);
    wr(d, DM_CRC_RES, (1u << 16) | CRC_START);              /* + PN9 dewhitening */

    /* channels: the 3 FFT bins around each, and the NCO that moves it to 0 Hz:
       2^32 * 1000 / Fs = 954437 + 796/4500 per kHz (32-bit math only) */
    for (b = 0u; b < (uint32_t)SPEC_FFT_N; b++) wr(d, HOP_CHMAP, (15u << 8) | b);
    for (c = 0u; c < CFG_HOP_N; c++) {
        int32_t k_hz = ch_ofs_khz(c);
        int32_t bin = div_round(k_hz * SPEC_FFT_N, (int32_t)(CFG_SAMPLE_RATE_HZ / 1000u));
        int32_t k;

        for (k = -1; k <= 1; k++) wr(d, HOP_CHMAP, (c << 8) | ((uint32_t)(bin + k) & 0xFFu));
        wr(d, HOP_NCO + 4u * c, (uint32_t)(-k_hz * 954437 + div_round(-k_hz * 796, 4500)));
    }
    wr(d, HOP_MIN, CFG_HOP_MIN);

    wr(d, DSP_CTRL, CFG_IN_SHIFT);
    wr(d, SPEC_BIN0_REG, SPEC_BIN0);
    wr(d, CAP_WARMUP, CFG_WARMUP_SAMPLES);
    wr(d, CAP_LEN, CFG_CAPTURE_SAMPLES);
    wr(d, CAP_COL, ((CFG_CAPTURE_SAMPLES % CAP_RAW_COLS) << 16) | (CFG_CAPTURE_SAMPLES / CAP_RAW_COLS));
    return 0;
}

void dsp_rtl_play_start(dsp_rtl_t *d)
{
    d->ndec = 0u;
    d->nlog = 0u;
    wr(d, DSP_CTRL, 0x100u | CFG_IN_SHIFT);                 /* empty the delay line */
    wr(d, DM_CTRL, 0x6u);                                   /* demodulator from scratch */
    wr(d, DM_CTRL, 0x1u);
    wr(d, HOP_CTRL, (CFG_HOP_HOLD << 16) | (CFG_HOP_CONFIRM << 12) | (CFG_HOP_NOISE_SH << 8) |
                    (CFG_HOP_THR_SH << 4) | 1u);
    wr(d, CAP_MODE, 0x200u | CFG_LIVE_WF_SHIFT);            /* wait for a packet */
    d->spec_ctrl = 1u;
    wr(d, SPEC_CTRL, d->spec_ctrl);                         /* spectrum of every block */
    wr(d, CAP_CTRL, 0x1u);
}

void dsp_rtl_rearm(dsp_rtl_t *d)
{
    d->ndec = 0u;
    wr(d, CAP_CTRL, 0x1u);
}

void dsp_rtl_live_spectrum(dsp_rtl_t *d, int on)
{
    d->spec_ctrl = (d->spec_ctrl & ~1u) | (on ? 1u : 0u);
    wr(d, SPEC_CTRL, d->spec_ctrl);
}

void dsp_rtl_freeze(dsp_rtl_t *d, int on)
{
    d->spec_ctrl = (d->spec_ctrl & ~2u) | (on ? 2u : 0u);
    wr(d, SPEC_CTRL, d->spec_ctrl);
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

        if (((flags >> 6) & 3u) == 0u) {                    /* a whole packet after sync */
            cap_dec_t *p = &d->log[d->nlog % DSP_LOG_N];
            uint32_t n = rd(d, DM_RES_BYTES) & 0xFFu, k;

            if (n > CAP_DEC_BYTES) n = CAP_DEC_BYTES;
            p->valid = 1u;
            p->crc_ok = (uint8_t)((flags >> 3) & 1u);
            p->nbytes = (uint8_t)n;
            p->ch = (uint8_t)((rd(d, HOP_STATUS) >> 8) & 0xFu);
            for (k = 0u; k < n; k += 4u) {
                uint32_t w = rd(d, DM_PKT_MEM + k);
                uint32_t b;
                for (b = 0u; b < 4u && k + b < n; b++) p->bytes[k + b] = (uint8_t)(w >> (8u * b));
            }
            d->nlog++;
            if (state == DSP_CAP_RECORD && d->ndec < CAP_PKTS) d->dec[d->ndec++] = *p;
        }
        wr(d, DM_CTRL, 0x9u);                               /* enable + ack */
    }
    return state;
}

uint32_t dsp_rtl_in_count(const dsp_rtl_t *d)
{
    return rd(d, DSP_IN_COUNT);
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

void dsp_rtl_read_last(const dsp_rtl_t *d, uint8_t *dst)
{
    copy_words(d, SPEC_LAST, dst, SPEC_BINS / 4u);
}

void dsp_rtl_read_capture(const dsp_rtl_t *d, cap_data_t *c)
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
}

uint32_t dsp_rtl_hop_dets(const dsp_rtl_t *d)
{
    return rd(d, HOP_DETS);
}
