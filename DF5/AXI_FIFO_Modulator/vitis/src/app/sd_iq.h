/*
 * sd_iq.h -- I/Q files on the microSD card (FatFs):
 *
 *   replay   read a file (int16 I, int16 Q, little-endian, interleaved -- the
 *            sim.iq format) block by block and push it into iq_stream -> dsp_top;
 *   upload   write a file sent from the PC over JTAG: the host (scripts/
 *            sd_upload.tcl) puts commands and data into sd_iq_box in RAM, the
 *            main loop calls sd_iq_upload_poll().
 */
#ifndef SD_IQ_H
#define SD_IQ_H

#include <stdint.h>
#include "hal/sd_card.h"
#include "hal/iq_stream.h"

#define SD_IQ_FILE      "SIM.IQ"
#define SD_IQ_BUF       4096u          /* bytes per file read / upload chunk */
#define SD_IQ_MAGIC     0x55504C44u    /* "UPLD": the host checks it before writing */

enum { SD_IQ_CMD_NONE = 0, SD_IQ_CMD_CREATE, SD_IQ_CMD_WRITE, SD_IQ_CMD_CLOSE };

/* Mailbox for the JTAG upload; buf is also the replay read buffer. */
typedef struct {
    volatile uint32_t magic;
    volatile uint32_t cmd;             /* SD_IQ_CMD_*; the firmware sets 0 when done */
    volatile uint32_t len;             /* bytes in buf (WRITE) */
    volatile uint32_t status;          /* FRESULT of the last command, 0 = ok */
    volatile uint32_t total;           /* bytes written to the file so far */
    uint32_t buf[SD_IQ_BUF / 4u];      /* CREATE: file name, NUL-terminated */
} sd_iq_box_t;

extern sd_iq_box_t sd_iq_box;

/* Mount the card's file system. 0 = ok, else FRESULT. */
int sd_iq_mount(sd_card_t *sd, axi_qspi_t *spi);

/* Open name for replay; *n_samples = file size / 4. 0 = ok, else FRESULT. */
int sd_iq_open(const char *name, uint32_t *n_samples);

/* Push as much of the file as fits into the FIFO. Returns 1 at end of file. */
int sd_iq_feed(iq_stream_t *s);

void sd_iq_close(void);

/* Serve one upload command if the host has posted one. Returns 1 when a file
   was just closed (the upload is complete). */
int sd_iq_upload_poll(void);

#endif
