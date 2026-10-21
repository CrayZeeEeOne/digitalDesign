#include "app/view_time.h"
#include "gfx/plot.h"

/* Bit period in 1/64 sample (Fs / bitrate * 64 = 15000 at 4.5 MS/s, 19200 bit/s). */
#define BIT_T64 ((CFG_SAMPLE_RATE_HZ * 64u) / CFG_BITRATE)

/*
 * Capture sample shown at pixel column x of the box. 32-bit only (64-bit division
 * pulls a large libgcc routine): samples per column = (CFG_CAPTURE_SAMPLES / 128) /
 * (VIEW_TIME_POINTS / 128), both divisible by 128.
 */
static uint32_t x_to_sample(const plot_box_t *b, const zoom_t *z, uint16_t x)
{
    uint32_t span = zoom_span(z, VIEW_TIME_POINTS);
    uint32_t num = (uint32_t)z->off * b->w + (uint32_t)x * span;     /* column * w */

    return (num * (CFG_CAPTURE_SAMPLES / 128u)) / ((VIEW_TIME_POINTS / 128u) * b->w);
}

/* Pixel column of a capture sample, or -1 if it is outside the window. */
static int16_t sample_to_x(const plot_box_t *b, const zoom_t *z, uint32_t s)
{
    uint32_t s0 = x_to_sample(b, z, 0u);
    uint32_t s1 = x_to_sample(b, z, b->w);

    if (s < s0 || s >= s1) return -1;
    return (int16_t)(((s - s0) * b->w) / (s1 - s0));
}

/* "12.3MS" */
static void ms_label(char *buf, uint32_t s)
{
    uint32_t t = (s * 10000u) / CFG_SAMPLE_RATE_HZ;   /* 0.1 ms */
    char *p = plot_u32_to_str(buf, t / 10u);

    *p++ = '.';
    p = plot_u32_to_str(p, t % 10u);
    *p++ = 'M'; *p++ = 'S'; *p = '\0';
}

/* Visible start and end time under the box. */
static void time_axis(tft_t *tft, const plot_box_t *b, const zoom_t *z)
{
    char buf[12];
    uint16_t y = (uint16_t)(b->y0 + b->h + 2u);

    ms_label(buf, x_to_sample(b, z, 0u));
    tft_draw_text(tft, b->x0, y, buf, TFT_GRAY, TFT_BLACK, 1);
    ms_label(buf, x_to_sample(b, z, b->w));
    tft_draw_text(tft, (uint16_t)(b->x0 + b->w - plot_text_w(buf)), y, buf, TFT_GRAY, TFT_BLACK, 1);
}

/* Dotted line and "P1"/"P2" at the start of each packet. */
static void packet_marks(tft_t *tft, const plot_box_t *b, const cap_data_t *c, const zoom_t *z)
{
    uint8_t p;

    for (p = 0u; p < c->npkt; p++) {
        int16_t x = sample_to_x(b, z, c->pkt[p].start);
        char label[3] = { 'P', (char)('1' + p), '\0' };
        uint16_t y;

        if (x < 0) continue;
        for (y = (uint16_t)(b->y0 + 1u); y < b->y0 + b->h - 1u; y += 4u)
            tft_draw_vline(tft, (uint16_t)(b->x0 + x), y, 2u, TFT_WHITE);
        tft_draw_text(tft, (uint16_t)(b->x0 + x + 3), (uint16_t)(b->y0 + 3u), label, TFT_WHITE, TFT_BLACK, 1);
    }
}

/* One lane (I or Q): its own axis box, envelope of the visible columns, label. */
static void raw_lane(tft_t *tft, const plot_box_t *b, const plot_series_t *s, int32_t scale,
                     uint16_t color, const char *name)
{
    plot_axis_box(tft, b->x0, b->y0, b->w, b->h);
    plot_series_draw(tft, b, s, scale, color);
    tft_draw_text(tft, (uint16_t)(b->x0 + 3u), (uint16_t)(b->y0 + b->h - 10u), name, color, TFT_BLACK, 1);
}

void view_raw(tft_t *tft, const cap_data_t *c, const zoom_t *z)
{
    plot_box_t b = plot_area(tft);
    plot_box_t bi = b, bq = b;
    uint16_t span = zoom_span(z, VIEW_TIME_POINTS);
    const cap_raw_t *r = &c->raw[z->off];
    const cap_raw_t *all = &c->raw[0];
    plot_series_t si = { &r->i_lo, &r->i_hi, sizeof(cap_raw_t), span, 1u, 1u, 0 };
    plot_series_t sq = { &r->q_lo, &r->q_hi, sizeof(cap_raw_t), span, 1u, 1u, 0 };
    plot_series_t ai = { &all->i_lo, &all->i_hi, sizeof(cap_raw_t), CAP_RAW_COLS, 1u, 1u, 0 };
    plot_series_t aq = { &all->q_lo, &all->q_hi, sizeof(cap_raw_t), CAP_RAW_COLS, 1u, 1u, 0 };
    int32_t scale = plot_series_scale(&ai, 4);
    int32_t s2 = plot_series_scale(&aq, 4);

    if (s2 > scale) scale = s2;     /* same scale for both lanes and at every zoom */

    bi.h = (uint16_t)(b.h / 2u - 2u);
    bq.y0 = (uint16_t)(b.y0 + b.h / 2u + 2u);
    bq.h = bi.h;
    raw_lane(tft, &bi, &si, scale, TFT_CYAN, "I");
    raw_lane(tft, &bq, &sq, scale, TFT_YELLOW, "Q");
    packet_marks(tft, &bi, c, z);
    time_axis(tft, &b, z);
}

/* Value of the decoded bit stream at capture sample s: 0/1, or -1 outside packets. */
static int8_t bit_at(const cap_data_t *c, uint32_t s)
{
    uint8_t p;

    for (p = 0u; p < c->npkt; p++) {
        const cap_pkt_t *k = &c->pkt[p];
        uint32_t lo = k->first_bit - (BIT_T64 / 2u) / 64u;
        uint32_t idx;

        if (k->nbits == 0u || s < lo) continue;
        idx = ((s - k->first_bit + (BIT_T64 / 2u) / 64u) * 64u) / BIT_T64;
        if (idx < k->nbits) return (int8_t)cap_pkt_bit(k, (uint16_t)idx);
    }
    return -1;
}

static char hex_digit(uint8_t v) { return (char)(v < 10u ? '0' + (int)v : 'A' + (int)v - 10); }

void view_bits(tft_t *tft, const cap_data_t *c, const zoom_t *z)
{
    plot_box_t b = plot_area(tft);
    plot_box_t wave = b;
    int16_t y_hi, y_lo, y_idle, prev = 0;
    uint16_t x, y;
    uint8_t p;

    wave.h = 76u;
    y_hi = (int16_t)(wave.y0 + 18);
    y_lo = (int16_t)(wave.y0 + wave.h - 10);
    y_idle = (int16_t)((y_hi + y_lo) / 2);

    tft_draw_rect(tft, wave.x0, wave.y0, wave.w, wave.h, TFT_GRAY);

    for (x = 0u; x < wave.w; x++) {
        int8_t v = bit_at(c, x_to_sample(&wave, z, x));
        int16_t yy = (v < 0) ? y_idle : (v ? y_hi : y_lo);
        uint16_t color = (v < 0) ? TFT_GRAY : TFT_GREEN;

        if (x == 0u) prev = yy;
        plot_vline_clipped(tft, (uint16_t)(wave.x0 + x), prev, yy, (uint16_t)(wave.y0 + 1u),
                           (uint16_t)(wave.y0 + wave.h - 2u), color);
        prev = yy;
    }
    tft_draw_text(tft, (uint16_t)(wave.x0 + 3u), (uint16_t)(y_hi - 3), "1", TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(wave.x0 + 3u), (uint16_t)(y_lo - 3), "0", TFT_GRAY, TFT_BLACK, 1);
    packet_marks(tft, &wave, c, z);
    time_axis(tft, &wave, z);

    /*
     * Packets as text: bit count; decoded by the demodulator (sync found): CRC
     * status, the start of the bytes as text and the bytes in hex; otherwise the
     * raw slicer bits in hex (first bit = MSB).
     */
    y = (uint16_t)(wave.y0 + wave.h + 16u);
    for (p = 0u; p < c->npkt; p++) {
        const cap_pkt_t *k = &c->pkt[p];
        const cap_dec_t *d = (p < c->ndec) ? &c->dec[p] : 0;
        const uint8_t *bytes = d ? d->bytes : k->bits;
        char line[56];
        char *q = line;
        uint16_t nbytes = d ? d->nbytes : (uint16_t)(k->nbits / 8u), i;

        *q++ = 'P'; *q++ = (char)('1' + p); *q++ = ':'; *q++ = ' ';
        q = plot_u32_to_str(q, k->nbits);
        *q++ = ' '; *q++ = 'B'; *q++ = 'I'; *q++ = 'T'; *q++ = 'S'; *q = '\0';
        tft_draw_text(tft, b.x0, y, line, TFT_WHITE, TFT_BLACK, 1);
        if (d) {
            tft_draw_text(tft, (uint16_t)(b.x0 + 84u), y, d->crc_ok ? "CRC OK" : "CRC ERROR",
                          d->crc_ok ? TFT_GREEN : TFT_RED, TFT_BLACK, 1);
            q = line;
            *q++ = '"';
            for (i = 0u; i < 10u && i < nbytes; i++)
                *q++ = (bytes[i] >= 0x20u && bytes[i] < 0x60u) ? (char)bytes[i] : '.';
            *q++ = '"'; *q = '\0';
            tft_draw_text(tft, (uint16_t)(b.x0 + 150u), y, line, TFT_YELLOW, TFT_BLACK, 1);
        }
        else tft_draw_text(tft, (uint16_t)(b.x0 + 84u), y, "NO SYNC", TFT_GRAY, TFT_BLACK, 1);

        if (nbytes > 25u) nbytes = 25u;
        q = line;
        for (i = 0u; i < nbytes; i++) {
            *q++ = hex_digit((uint8_t)(bytes[i] >> 4));
            *q++ = hex_digit((uint8_t)(bytes[i] & 15u));
        }
        *q = '\0';
        tft_draw_text(tft, b.x0, (uint16_t)(y + 10u), line, d ? TFT_GREEN : TFT_GRAY, TFT_BLACK, 1);
        y = (uint16_t)(y + 28u);
    }
    if (c->npkt == 0u)
        tft_draw_text(tft, b.x0, y, "NO PACKET IN CAPTURE", TFT_RED, TFT_BLACK, 1);
}
