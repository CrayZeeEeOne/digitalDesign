#include "hal/sd_host.h"
#include "xil_io.h"

#define SDH_CTRL        0x000u    /* [7:0] div [11:8] sdly [12] free [16] fmt8 */
#define SDH_STATUS      0x004u    /* [0] command [1] data [2] stream; errors 8:4 */
#define SDH_ARG         0x008u
#define SDH_CMD         0x00Cu    /* [5:0] idx [7:6] rsp [8] busy [9] crc [11:10] data */
#define SDH_RESP        0x010u    /* + 4 * word */
#define SDH_ST_LBA      0x020u
#define SDH_ST_CNT      0x024u
#define SDH_ST_CTRL     0x028u    /* [0] start [1] stop [2] flush */
#define SDH_RATE        0x034u
#define SDH_UNDER       0x038u
#define SDH_ID          0x03Cu
#define SDH_OUT         0x040u
#define SDH_BUF         0x200u

#define SDH_ID_VAL      0x53440001u
#define CMD_POLLS       5000000u  /* ~1 s of status reads: a write may stay busy that long */

static inline uint32_t rd(const sd_host_t *h, uint32_t r) { return Xil_In32(h->base + r); }
static inline void wr(const sd_host_t *h, uint32_t r, uint32_t v) { Xil_Out32(h->base + r, v); }

int sd_host_init(sd_host_t *h, uint32_t base)
{
    h->base = base;
    if (rd(h, SDH_ID) != SDH_ID_VAL) return -1;
    sd_host_stream_stop(h);
    sd_host_clock(h, 124u, 2u, 0);
    return 0;
}

void sd_host_clock(sd_host_t *h, uint8_t div, uint8_t sdly, int free)
{
    h->ctrl = (h->ctrl & (1u << 16)) | ((uint32_t)(sdly & 15u) << 8) | div | (free ? (1u << 12) : 0u);
    wr(h, SDH_CTRL, h->ctrl);
}

uint32_t sd_host_cmd(sd_host_t *h, uint8_t idx, uint32_t arg, int rsp, int busy, int crc, int data)
{
    uint32_t n, st = 0u;

    wr(h, SDH_ARG, arg);
    wr(h, SDH_CMD, ((uint32_t)data << 10) | (crc ? (1u << 9) : 0u) | (busy ? (1u << 8) : 0u) |
                   ((uint32_t)rsp << 6) | (idx & 63u));
    for (n = 0u; n < CMD_POLLS; n++) {
        st = rd(h, SDH_STATUS);
        if ((st & 3u) == 0u) return st & SDH_ST_ERRORS;
    }
    return SDH_ST_CMD_TMO;
}

uint32_t sd_host_resp(const sd_host_t *h, int word)
{
    return rd(h, SDH_RESP + 4u * (uint32_t)word);
}

void sd_host_buf_read(const sd_host_t *h, uint8_t *dst)
{
    uint32_t w;
    for (w = 0u; w < 128u; w++) {
        uint32_t v = rd(h, SDH_BUF + 4u * w);
        dst[0] = (uint8_t)v;
        dst[1] = (uint8_t)(v >> 8);
        dst[2] = (uint8_t)(v >> 16);
        dst[3] = (uint8_t)(v >> 24);
        dst += 4;
    }
}

void sd_host_buf_write(const sd_host_t *h, const uint8_t *src)
{
    uint32_t w;
    for (w = 0u; w < 128u; w++) {
        wr(h, SDH_BUF + 4u * w, (uint32_t)src[0] | ((uint32_t)src[1] << 8) |
                                ((uint32_t)src[2] << 16) | ((uint32_t)src[3] << 24));
        src += 4;
    }
}

void sd_host_stream_format(sd_host_t *h, uint32_t rate, int fmt8)
{
    h->ctrl = (h->ctrl & ~(1u << 16)) | (fmt8 ? (1u << 16) : 0u);
    wr(h, SDH_CTRL, h->ctrl);
    wr(h, SDH_RATE, rate);
}

void sd_host_stream(sd_host_t *h, uint32_t lba, uint32_t count)
{
    wr(h, SDH_ST_LBA, lba);
    wr(h, SDH_ST_CNT, count);
    wr(h, SDH_ST_CTRL, 1u);
}

void sd_host_stream_stop(sd_host_t *h)
{
    uint32_t n;

    wr(h, SDH_ST_CTRL, 2u);
    for (n = 0u; n < CMD_POLLS && (rd(h, SDH_STATUS) & 7u); n++)
        ;
}

void sd_host_stream_flush(sd_host_t *h)
{
    wr(h, SDH_ST_CTRL, 4u);
}

int sd_host_stream_busy(const sd_host_t *h)
{
    return (rd(h, SDH_STATUS) & 4u) != 0u;
}

uint32_t sd_host_status(const sd_host_t *h)
{
    return rd(h, SDH_STATUS);
}

uint32_t sd_host_out_count(const sd_host_t *h)
{
    return rd(h, SDH_OUT);
}

void sd_host_out_clear(sd_host_t *h)
{
    wr(h, SDH_OUT, 0u);
    wr(h, SDH_UNDER, 0u);
}

uint32_t sd_host_underruns(const sd_host_t *h)
{
    return rd(h, SDH_UNDER);
}
