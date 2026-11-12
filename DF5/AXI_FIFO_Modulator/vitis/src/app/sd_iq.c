#include "app/sd_iq.h"
#include "lib/fatfs/ff.h"
#include "lib/fatfs/diskio_sd.h"

sd_iq_box_t sd_iq_box;

static FATFS fs;
static FIL wr_file;            /* upload */
static uint8_t wr_open;

/* replay: the file as runs of consecutive blocks on the card */
static sd_host_t *host;
static sd_card_t *card;
static struct { uint32_t lba, blocks; } runs[SD_IQ_RUNS];
static uint32_t nruns, run_next;     /* runs of the file / the next one to stream */
static uint32_t len_samples;         /* samples in the file */
static uint8_t done;                 /* every sample of the file is out */
static uint32_t play_rate;
static uint8_t playing, fmt8;

int sd_iq_mount(sd_card_t *sd, sd_host_t *h)
{
    sd_iq_box.magic = SD_IQ_MAGIC;
    host = h;
    card = sd;
    diskio_sd_attach(sd, h);
    return (int)f_mount(&fs, "", 1);
}

/* *.IQ8: int8 samples */
static int name_is_iq8(const char *name)
{
    const char *p = name;
    while (*p) p++;
    return p - name >= 4 && p[-1] == '8' && (p[-2] == 'Q' || p[-2] == 'q');
}

int sd_iq_open(const char *name, uint32_t *n_samples)
{
    static DWORD clmt[2u * SD_IQ_RUNS + 2u];
    FIL f;
    FRESULT fr;
    uint32_t i, left;

    sd_iq_close();
    fr = f_open(&f, name, FA_READ);
    if (fr != FR_OK) return (int)fr;

    /* the cluster map: [size] (clusters, first cluster) ... 0 */
    f.cltbl = clmt;
    clmt[0] = sizeof(clmt) / sizeof(clmt[0]);
    fr = f_lseek(&f, CREATE_LINKMAP);
    if (fr != FR_OK) { f_close(&f); return (int)fr; }

    fmt8 = (uint8_t)name_is_iq8(name);
    len_samples = (uint32_t)(f_size(&f) / (fmt8 ? 2u : 4u));
    left = (uint32_t)((f_size(&f) + SD_BLOCK - 1u) / SD_BLOCK);
    nruns = 0u;
    for (i = 1u; clmt[i] != 0u && nruns < SD_IQ_RUNS && left; i += 2u) {
        uint32_t blocks = clmt[i] * fs.csize;
        runs[nruns].lba = (uint32_t)(fs.database + (LBA_t)(clmt[i + 1u] - 2u) * fs.csize);
        runs[nruns].blocks = (blocks < left) ? blocks : left;
        left -= runs[nruns].blocks;
        nruns++;
    }
    f_close(&f);
    *n_samples = len_samples;
    return left ? (int)FR_NOT_ENOUGH_CORE : 0;
}

static void start_run(void)
{
    sd_host_stream(host, sd_addr(card, runs[run_next].lba), runs[run_next].blocks);
    run_next++;
}

void sd_iq_play(uint32_t rate)
{
    if (!nruns) return;
    sd_host_stream_stop(host);
    sd_host_stream_flush(host);
    play_rate = rate;
    sd_host_stream_format(host, rate, fmt8);
    sd_host_out_clear(host);
    done = 0u;
    run_next = 0u;
    playing = 1u;
    start_run();
}

int sd_iq_poll(void)
{
    if (!playing || done) return 0;
    if (!sd_host_stream_busy(host) && run_next < nruns) start_run();
    if (sd_host_out_count(host) >= len_samples) {     /* the last sample went to the DSP */
        done = 1u;
        return 1;
    }
    return 0;
}

void sd_iq_pause(int on)
{
    /* rate 1: one sample every 43 s -- the stream stands, the card waits */
    if (playing) sd_host_stream_format(host, on ? 1u : play_rate, fmt8);
}

uint32_t sd_iq_pos(void)
{
    uint32_t n = playing ? sd_host_out_count(host) : 0u;
    return (n < len_samples) ? n : len_samples;
}

uint32_t sd_iq_len(void)
{
    return len_samples;
}

void sd_iq_close(void)
{
    if (host) sd_host_stream_stop(host);
    playing = 0u;
}

int sd_iq_upload_poll(void)
{
    uint32_t cmd = sd_iq_box.cmd;
    FRESULT fr = FR_OK;
    int closed = 0;

    if (cmd == SD_IQ_CMD_NONE) return 0;

    switch (cmd) {
    case SD_IQ_CMD_CREATE:
        sd_iq_close();                           /* the card is ours now */
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
