#include "app/view_time.h"
#include "gfx/plot.h"
#include "app/frame.h"

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

/* Visible start and end time under the box (padded: the old labels are erased). */
static void time_axis(tft_t *tft, const plot_box_t *b, const zoom_t *z)
{
    char buf[12];
    uint16_t y = (uint16_t)(b->y0 + b->h + 2u);

    ms_label(buf, x_to_sample(b, z, 0u));
    plot_text_pad(tft, b->x0, y, buf, 7u, TFT_GRAY);
    ms_label(buf, x_to_sample(b, z, b->w));
    plot_text_pad(tft, (uint16_t)(b->x0 + b->w - 7u * 6u), y, "", 7u, TFT_GRAY);
    tft_draw_text(tft, (uint16_t)(b->x0 + b->w - plot_text_w(buf)), y, buf, TFT_GRAY, TFT_BLACK, 1);
}

/* Columns of the packet starts in the box (-1: not visible). */
static void packet_cols(const plot_box_t *b, const cap_data_t *c, const zoom_t *z, int16_t *x)
{
    uint8_t p;

    for (p = 0u; p < CAP_PKTS; p++)
        x[p] = (p < c->npkt) ? sample_to_x(b, z, c->pkt[p].start) : -1;
}

/* Dotted packet-start line in a column (white, 2 on / 2 off). */
static void packet_dots(plot_col_t *col, uint16_t x, const int16_t *px)
{
    uint8_t p;
    int16_t y;

    for (p = 0u; p < CAP_PKTS; p++)
        if (px[p] == (int16_t)x)
            for (y = 1; y < (int16_t)col->h - 1; y += 4) {
                plot_col_dot(col, y, TFT_WHITE);
                plot_col_dot(col, (int16_t)(y + 1), TFT_WHITE);
            }
}

/* "P1"/"P2" next to the packet lines. */
static void packet_labels(tft_t *tft, const plot_box_t *b, const int16_t *px)
{
    uint8_t p;

    for (p = 0u; p < CAP_PKTS; p++) {
        char label[3] = { 'P', (char)('1' + p), '\0' };
        if (px[p] >= 0 && px[p] + 15 < (int16_t)b->w)
            tft_draw_text(tft, (uint16_t)(b->x0 + px[p] + 3), (uint16_t)(b->y0 + 3u), label, TFT_WHITE, TFT_BLACK, 1);
    }
}

/* Axis box of a lane in one column: frame, center cross. */
static void box_column(plot_col_t *col, uint16_t x, uint16_t w)
{
    uint16_t h = col->h;

    if (x == 0u || x == w - 1u) {
        plot_col_span(col, 0, (int16_t)(h - 1u), TFT_GRAY);
        return;
    }
    plot_col_dot(col, 0, TFT_GRAY);
    plot_col_dot(col, (int16_t)(h - 1u), TFT_GRAY);
    if (x >= 2u && x < w - 2u) plot_col_dot(col, (int16_t)(h / 2u), TFT_GRAY);
    if (x == w / 2u) plot_col_span(col, 2, (int16_t)(h - 3u), TFT_GRAY);
}

static int8_t raw_val(const cap_raw_t *r, uint8_t q, uint8_t hi)
{
    return q ? (hi ? r->q_hi : r->q_lo) : (hi ? r->i_hi : r->i_lo);
}

/* One lane (I or Q): envelope of the visible columns, joined column to column. */
static void raw_lane(tft_t *tft, const plot_box_t *b, const cap_data_t *c, const zoom_t *z,
                     int32_t scale, uint8_t q, uint16_t color, const int16_t *pkx)
{
    plot_col_t *colp = &plot_scratch.col;
    uint16_t span = zoom_span(z, VIEW_TIME_POINTS);
    int16_t half = (int16_t)(b->h / 2u), amp = (int16_t)(b->h / 2u - 3u);
    int16_t pt = 0, pb = 0;
    uint16_t x;

    for (x = 0u; x < b->w; x++) {
        const cap_raw_t *r = &c->raw[z->off + ((uint32_t)x * span) / b->w];
        int16_t t = (int16_t)(half - (raw_val(r, q, 1u) * amp) / scale);
        int16_t bo = (int16_t)(half - (raw_val(r, q, 0u) * amp) / scale);

        plot_col_fill(colp, b->h, TFT_BLACK);
        box_column(colp, x, b->w);
        packet_dots(colp, x, pkx);
        if (x == 0u) { pt = t; pb = bo; }
        if (x > 0u && x < b->w - 1u)
            plot_col_span(colp, (t < pb) ? t : pb, (bo > pt) ? bo : pt, color);
        plot_col_send(tft, (uint16_t)(b->x0 + x), b->y0, colp);
        pt = t;
        pb = bo;
    }
}

void view_raw(tft_t *tft, const cap_data_t *c, const zoom_t *z, int full)
{
    plot_box_t b = plot_area(tft);
    plot_box_t bi = b, bq = b;
    int32_t scale = 4;
    int16_t pkx[CAP_PKTS];
    uint16_t k;

    (void)full;
    /* same scale for both lanes and at every zoom: the largest value of the capture */
    for (k = 0u; k < CAP_RAW_COLS; k++) {
        const cap_raw_t *r = &c->raw[k];
        int32_t m = r->i_hi;
        if (-r->i_lo > m) m = -r->i_lo;
        if (r->q_hi > m) m = r->q_hi;
        if (-r->q_lo > m) m = -r->q_lo;
        if (m > scale) scale = m;
    }
    scale += scale >> 3;

    bi.h = (uint16_t)(b.h / 2u - 2u);
    bq.y0 = (uint16_t)(b.y0 + b.h / 2u + 2u);
    bq.h = bi.h;
    packet_cols(&bi, c, z, pkx);
    raw_lane(tft, &bi, c, z, scale, 0u, TFT_CYAN, pkx);
    raw_lane(tft, &bq, c, z, scale, 1u, TFT_YELLOW, pkx);
    tft_draw_text(tft, (uint16_t)(bi.x0 + 3u), (uint16_t)(bi.y0 + bi.h - 10u), "I", TFT_CYAN, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(bq.x0 + 3u), (uint16_t)(bq.y0 + bq.h - 10u), "Q", TFT_YELLOW, TFT_BLACK, 1);
    packet_labels(tft, &bi, pkx);
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

#define BITS_TEXT_W 52u        /* characters per text line: erases the old line */

/* Small line builder for the text under the waveform. */
typedef struct { char buf[BITS_TEXT_W + 1u]; char *p; } line_t;
static void l_start(line_t *l) { l->p = l->buf; *l->p = '\0'; }
static void l_str(line_t *l, const char *s) { while (*s && l->p < l->buf + BITS_TEXT_W) *l->p++ = *s++; *l->p = '\0'; }
static void l_u32(line_t *l, uint32_t v) { char t[11]; plot_u32_to_str(t, v); l_str(l, t); }
static void l_hex8(line_t *l, uint8_t v) { char t[3] = { hex_digit((uint8_t)(v >> 4)), hex_digit((uint8_t)(v & 15u)), 0 }; l_str(l, t); }

/* "866.700M" */
static void l_mhz(line_t *l, uint32_t khz)
{
    char t[4] = { (char)('0' + (khz % 1000u) / 100u), (char)('0' + (khz % 100u) / 10u), (char)('0' + khz % 10u), 0 };
    l_u32(l, khz / 1000u);
    l_str(l, ".");
    l_str(l, t);
    l_str(l, "M");
}

void view_bits(tft_t *tft, const cap_data_t *c, const zoom_t *z, int full, const rx_stats_t *st)
{
    plot_col_t *colp = &plot_scratch.col;
    plot_box_t b = plot_area(tft);
    plot_box_t wave = b;
    int16_t y_hi, y_lo, y_idle, prev = 0;
    int16_t pkx[CAP_PKTS];
    uint16_t x, y;
    uint8_t p;
    line_t l;

    (void)full;
    wave.h = 76u;
    y_hi = 18;
    y_lo = (int16_t)(wave.h - 10u);
    y_idle = (int16_t)((y_hi + y_lo) / 2);
    packet_cols(&wave, c, z, pkx);

    for (x = 0u; x < wave.w; x++) {
        int8_t v = bit_at(c, x_to_sample(&wave, z, x));
        int16_t yy = (v < 0) ? y_idle : (v ? y_hi : y_lo);

        plot_col_fill(colp, wave.h, TFT_BLACK);
        if (x == 0u || x == wave.w - 1u) plot_col_span(colp, 0, (int16_t)(wave.h - 1u), TFT_GRAY);
        else {
            plot_col_dot(colp, 0, TFT_GRAY);
            plot_col_dot(colp, (int16_t)(wave.h - 1u), TFT_GRAY);
        }
        packet_dots(colp, x, pkx);
        if (x == 0u) prev = yy;
        if (x > 0u && x < wave.w - 1u) plot_col_span(colp, prev, yy, (v < 0) ? TFT_GRAY : TFT_GREEN);
        plot_col_send(tft, (uint16_t)(wave.x0 + x), wave.y0, colp);
        prev = yy;
    }
    tft_draw_text(tft, (uint16_t)(wave.x0 + 3u), (uint16_t)(wave.y0 + y_hi - 3), "1", TFT_GRAY, TFT_BLACK, 1);
    tft_draw_text(tft, (uint16_t)(wave.x0 + 3u), (uint16_t)(wave.y0 + y_lo - 3), "0", TFT_GRAY, TFT_BLACK, 1);
    packet_labels(tft, &wave, pkx);
    time_axis(tft, &wave, z);

    /*
     * Packets as text, three lines each. Decoded by the demodulator (sync found):
     * channel, radio CRC16, CRC8 of the alarm frame; number, command, alarm
     * counter, zones; the 16 bytes in hex. Otherwise "NO SYNC" and the raw
     * slicer bits in hex. Every line is padded to the full width, so a shorter
     * new line erases the old one.
     */
    y = (uint16_t)(wave.y0 + wave.h + 14u);
    for (p = 0u; p < CAP_PKTS; p++) {
        const cap_pkt_t *k = &c->pkt[p];
        const cap_dec_t *d = (p < c->ndec) ? &c->dec[p] : 0;
        frame_t f;
        uint16_t i, nbytes;

        if (p >= c->npkt) {
            plot_text_pad(tft, b.x0, y, (p == 0u) ? "NO PACKET IN CAPTURE" : "", BITS_TEXT_W, TFT_RED);
            plot_text_pad(tft, b.x0, (uint16_t)(y + 10u), "", BITS_TEXT_W, TFT_GRAY);
            plot_text_pad(tft, b.x0, (uint16_t)(y + 20u), "", BITS_TEXT_W, TFT_GRAY);
            y = (uint16_t)(y + 32u);
            continue;
        }

        /* line 1: P1 866.700M  CRC16 OK  CRC8 OK   (or the bit count without sync) */
        l_start(&l);
        l_str(&l, "P");
        l_u32(&l, p + 1u);
        l_str(&l, " ");
        if (d) {
            frame_parse(d, &f);
            l_mhz(&l, frame_ch_khz(d->ch));
            plot_text_pad(tft, b.x0, y, l.buf, 13u, TFT_WHITE);
            plot_text_pad(tft, (uint16_t)(b.x0 + 78u), y, d->crc_ok ? "CRC16 OK" : "CRC16 ERR", 10u,
                          d->crc_ok ? TFT_GREEN : TFT_RED);
            plot_text_pad(tft, (uint16_t)(b.x0 + 138u), y, !f.complete ? "NO FRAME" : f.crc8_ok ? "CRC8 OK" : "CRC8 ERR",
                          BITS_TEXT_W - 23u, (f.complete && f.crc8_ok) ? TFT_GREEN : TFT_RED);
        } else {
            l_u32(&l, k->nbits);
            l_str(&l, " BITS  NO SYNC");
            plot_text_pad(tft, b.x0, y, l.buf, BITS_TEXT_W, TFT_GRAY);
        }

        /* line 2: #3561 ALARM 233 ZONES 07 FIELD 04 */
        l_start(&l);
        if (d && f.complete) {
            l_str(&l, "#");
            l_u32(&l, f.pkt_num);
            l_str(&l, (f.cmd == FRAME_CMD_ALARM) ? " ALARM " : " CMD ");
            if (f.cmd != FRAME_CMD_ALARM) { l_hex8(&l, f.cmd); l_str(&l, " CNT "); }
            l_u32(&l, f.alarm_cnt);
            l_str(&l, "  ZONES ");
            l_hex8(&l, f.zones);
            l_str(&l, "  FIELD ");
            l_hex8(&l, f.alarm);
            l_str(&l, "  SENSOR ");
            l_u32(&l, f.num_sensor);
        }
        plot_text_pad(tft, b.x0, (uint16_t)(y + 10u), l.buf, BITS_TEXT_W, TFT_YELLOW);

        /* line 3: the bytes in hex */
        nbytes = d ? d->nbytes : (uint16_t)(k->nbits / 8u);
        if (nbytes > 25u) nbytes = 25u;
        l_start(&l);
        for (i = 0u; i < nbytes; i++) l_hex8(&l, d ? d->bytes[i] : k->bits[i]);
        plot_text_pad(tft, b.x0, (uint16_t)(y + 20u), l.buf, BITS_TEXT_W, d ? TFT_GREEN : TFT_GRAY);
        y = (uint16_t)(y + 32u);
    }

    /* statistics since the file started */
    if (st) {
        l_start(&l);
        l_str(&l, "RX ");
        l_u32(&l, st->rx);
        l_str(&l, "  CRC16 ");
        l_u32(&l, st->crc16);
        l_str(&l, "  CRC8 ");
        l_u32(&l, st->crc8);
        l_str(&l, "  HOP ");
        l_u32(&l, st->hop_ok);
        l_str(&l, "/");
        l_u32(&l, st->hop_n);
        plot_text_pad(tft, b.x0, y, l.buf, BITS_TEXT_W, TFT_CYAN);
    }
}
