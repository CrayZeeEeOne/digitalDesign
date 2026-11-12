/*
 * sd_host.h -- driver of sd_host_top: the microSD card on the native SD bus
 * (4 data lines) in the PL (register map in vivado/sources/rtl/sd_host.sv).
 *
 *   commands   sd_host_cmd(): index, argument, response type, optional busy
 *              wait and one data block through the 512-byte buffer
 *   stream     sd_host_stream(): a run of blocks (one CMD18) goes straight into
 *              dsp_top at the RATE sample rate, int8 or int16 I/Q
 *
 * hal/sd_card.c builds the card protocol on top of it.
 */
#ifndef SD_HOST_H
#define SD_HOST_H

#include <stdint.h>

typedef struct {
    uint32_t base;
    uint32_t ctrl;             /* CTRL as last written */
} sd_host_t;

enum {                         /* response of a command */
    SDH_RSP_NONE = 0, SDH_RSP_48 = 1, SDH_RSP_136 = 2
};
enum {                         /* data of a command */
    SDH_DATA_NONE = 0, SDH_DATA_READ = 1, SDH_DATA_WRITE = 2
};

#define SDH_ST_CMD_TMO   (1u << 4)
#define SDH_ST_CMD_CRC   (1u << 5)
#define SDH_ST_DAT_TMO   (1u << 6)
#define SDH_ST_DAT_CRC   (1u << 7)
#define SDH_ST_WR_ERR    (1u << 8)
#define SDH_ST_ERRORS    0x1F0u

/* 0 = found (ID), -1 = not found. Clock 400 kHz, stream off. */
int sd_host_init(sd_host_t *h, uint32_t base);

/* Bus clock: f = f_aclk / (2 * (div + 1)); inputs read sdly AXI clocks after
   the rising edge; free = clock runs without a command (power-up clocks). */
void sd_host_clock(sd_host_t *h, uint8_t div, uint8_t sdly, int free);

/* One command; waits for it (and its data block, busy) to finish. Returns the
   error bits of STATUS (SDH_ST_*), 0 = ok. busy: wait for DAT0 (R1b); crc:
   check the CRC7 of a 48-bit response (not for R3). */
uint32_t sd_host_cmd(sd_host_t *h, uint8_t idx, uint32_t arg, int rsp, int busy, int crc, int data);

/* Response: 48 bits -> word 0 = the 32-bit content; 136 bits -> words 3..0 = bits 127..0. */
uint32_t sd_host_resp(const sd_host_t *h, int word);

/* The 512-byte block buffer. */
void sd_host_buf_read(const sd_host_t *h, uint8_t *dst);
void sd_host_buf_write(const sd_host_t *h, const uint8_t *src);

/* Stream: output rate (2^32 * Fs / f_aclk, 0 = as fast as possible), int8 file. */
void sd_host_stream_format(sd_host_t *h, uint32_t rate, int fmt8);

/* Read count blocks from lba (one CMD18, then CMD12) into the output stream. */
void sd_host_stream(sd_host_t *h, uint32_t lba, uint32_t count);
void sd_host_stream_stop(sd_host_t *h);     /* CMD12 now; waits until idle */
void sd_host_stream_flush(sd_host_t *h);    /* empty the FIFO (stream stopped) */
int sd_host_stream_busy(const sd_host_t *h);
uint32_t sd_host_status(const sd_host_t *h);

/* Samples handed to dsp_top since sd_host_out_clear(); ticks without a sample. */
uint32_t sd_host_out_count(const sd_host_t *h);
void sd_host_out_clear(sd_host_t *h);
uint32_t sd_host_underruns(const sd_host_t *h);

#endif
