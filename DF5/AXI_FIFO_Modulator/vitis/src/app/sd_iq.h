/*
 * sd_iq.h -- I/Q files on the microSD card (FatFs):
 *
 *   replay   the file goes from the card straight into dsp_top through the PL
 *            stream of sd_host (no samples through the processor): FatFs only
 *            finds where the file lies (its cluster runs, fast seek), sd_host
 *            reads each run with one CMD18 and hands the samples on at 4.5 MS/s.
 *            *.IQ8 -- int8 I, int8 Q (9 MB/s: real time on the 4-bit bus at
 *            25 MHz); other names -- int16 I, int16 Q (18 MB/s: ~0.7x real time).
 *   upload   write a file sent from the PC over JTAG: the host (tools/
 *            sd_upload.py) puts commands and data into sd_iq_box in RAM, the
 *            main loop calls sd_iq_upload_poll().
 */
#ifndef SD_IQ_H
#define SD_IQ_H

#include <stdint.h>
#include "hal/sd_card.h"
#include "hal/sd_host.h"

#define SD_IQ_BUF       4096u          /* bytes per upload chunk */
#define SD_IQ_MAGIC     0x55504C44u    /* "UPLD": the host checks it before writing */
#define SD_IQ_RUNS      16u            /* cluster runs of a replay file at most */

enum { SD_IQ_CMD_NONE = 0, SD_IQ_CMD_CREATE, SD_IQ_CMD_WRITE, SD_IQ_CMD_CLOSE };

/* Mailbox for the JTAG upload. */
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
int sd_iq_mount(sd_card_t *sd, sd_host_t *host);

/* Find name on the card and where it lies. *n_samples = its samples (int8 for
   *.IQ8, else int16). 0 = ok, else FRESULT (FR_NOT_ENOUGH_CORE: more than
   SD_IQ_RUNS fragments -- copy the file onto an empty card). */
int sd_iq_open(const char *name, uint32_t *n_samples);

/* Start the replay from the first sample, rate = 2^32 * Fs / f_aclk. */
void sd_iq_play(uint32_t rate);

/* Keep the stream going: the next cluster run when one is read. The file is
   played once: returns 1 (once) when its last sample has gone to the DSP. */
int sd_iq_poll(void);

/* Pause (no samples out, the card stops when the FIFO is full) / go on. */
void sd_iq_pause(int on);

/* Samples handed to the DSP / in the file. */
uint32_t sd_iq_pos(void);
uint32_t sd_iq_len(void);

/* Stop the stream (before any other card access: FatFs, card test). */
void sd_iq_close(void);

/* Serve one upload command if the host has posted one. Returns 1 when a file
   was just closed (the upload is complete). */
int sd_iq_upload_poll(void);

#endif
