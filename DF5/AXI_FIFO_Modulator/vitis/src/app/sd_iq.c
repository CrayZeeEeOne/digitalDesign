#include "app/sd_iq.h"
#include "lib/fatfs/ff.h"
#include "lib/fatfs/diskio_sd.h"

sd_iq_box_t sd_iq_box;

static FATFS fs;
static FIL rd_file;            /* replay */
static FIL wr_file;            /* upload */
static uint32_t rd_pos, rd_fill;     /* bytes used / valid in sd_iq_box.buf */
static uint8_t rd_open, wr_open;

int sd_iq_mount(sd_card_t *sd, axi_qspi_t *spi)
{
    sd_iq_box.magic = SD_IQ_MAGIC;
    diskio_sd_attach(sd, spi);
    return (int)f_mount(&fs, "", 1);
}

int sd_iq_open(const char *name, uint32_t *n_samples)
{
    FRESULT fr;

    if (rd_open) sd_iq_close();
    fr = f_open(&rd_file, name, FA_READ);
    if (fr != FR_OK) return (int)fr;
    rd_open = 1u;
    rd_pos = rd_fill = 0u;
    *n_samples = (uint32_t)(f_size(&rd_file) / 4u);
    return 0;
}

int sd_iq_feed(iq_stream_t *s)
{
    uint32_t space;

    if (!rd_open) return 1;
    space = iq_stream_space(s);
    while (space) {
        uint32_t n;

        if (rd_pos >= rd_fill) {
            UINT br = 0;
            if (f_read(&rd_file, sd_iq_box.buf, SD_IQ_BUF, &br) != FR_OK || br < 4u) return 1;
            rd_fill = br & ~3u;                  /* whole I/Q pairs only */
            rd_pos = 0u;
        }
        n = (rd_fill - rd_pos) / 4u;
        if (n > space) n = space;
        iq_stream_push(s, &sd_iq_box.buf[rd_pos / 4u], n);
        rd_pos += n * 4u;
        space -= n;
    }
    return 0;
}

void sd_iq_close(void)
{
    if (rd_open) f_close(&rd_file);
    rd_open = 0u;
}

int sd_iq_upload_poll(void)
{
    uint32_t cmd = sd_iq_box.cmd;
    FRESULT fr = FR_OK;
    int closed = 0;

    if (cmd == SD_IQ_CMD_NONE) return 0;

    switch (cmd) {
    case SD_IQ_CMD_CREATE:
        sd_iq_close();                           /* the buffer is ours now */
        if (wr_open) f_close(&wr_file);
        ((char *)sd_iq_box.buf)[SD_IQ_BUF - 1u] = '\0';
        fr = f_open(&wr_file, (const char *)sd_iq_box.buf, FA_CREATE_ALWAYS | FA_WRITE);
        wr_open = (uint8_t)(fr == FR_OK);
        sd_iq_box.total = 0u;
        break;
    case SD_IQ_CMD_WRITE: {
        UINT bw = 0;
        uint32_t n = sd_iq_box.len;
        if (!wr_open) { fr = FR_NO_FILE; break; }
        if (n > SD_IQ_BUF) n = SD_IQ_BUF;
        fr = f_write(&wr_file, sd_iq_box.buf, n, &bw);
        if (fr == FR_OK && bw != n) fr = FR_DENIED;      /* card full */
        sd_iq_box.total += bw;
        break;
    }
    case SD_IQ_CMD_CLOSE:
        if (wr_open) fr = f_close(&wr_file);
        wr_open = 0u;
        closed = 1;
        break;
    default:
        fr = FR_INVALID_PARAMETER;
        break;
    }
    sd_iq_box.status = (uint32_t)fr;
    sd_iq_box.cmd = SD_IQ_CMD_NONE;
    return closed;
}
