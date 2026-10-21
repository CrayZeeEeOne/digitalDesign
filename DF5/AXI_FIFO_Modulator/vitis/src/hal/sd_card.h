/*
 * sd_card.h -- microSD card in SPI mode over the AXI Quad SPI (hal/axi_qspi).
 *
 *   sd_init()  power-up clocks, CMD0, CMD8, ACMD41, CMD58, CMD9;
 *   sd_read()  one 512-byte block (CMD17);
 *   sd_write() one 512-byte block (CMD24), waits until the card has stored it.
 *
 * The SPI runs at a fixed 6.25 MHz (hal/axi_qspi.h), also during identification
 * (specified <= 400 kHz; the core cannot divide further, cards accept it).
 * SD Physical Layer Simplified Specification, chapter 7 (SPI mode).
 */
#ifndef SD_CARD_H
#define SD_CARD_H

#include <stdint.h>
#include "hal/axi_qspi.h"

#define SD_BLOCK 512u

enum {
    SD_OK = 0,
    SD_ERR_NO_CARD = -1,       /* no answer to CMD0: no card or bad wiring */
    SD_ERR_CMD8    = -2,       /* unexpected CMD8 answer */
    SD_ERR_ACMD41  = -3,       /* card never left the idle state */
    SD_ERR_CMD58   = -4,       /* OCR not readable */
    SD_ERR_CSD     = -5,       /* CSD not readable */
    SD_ERR_READ    = -6,       /* CMD17 rejected or no data token */
    SD_ERR_NOT_INIT = -7,
    SD_ERR_WRITE   = -8,       /* CMD24 rejected, data not accepted or busy timeout */
    SD_ERR_LOCKED  = -9        /* password-locked (CMD13): reads/writes are illegal commands */
};

enum { SD_TYPE_NONE = 0, SD_TYPE_V1, SD_TYPE_V2_SC, SD_TYPE_SDHC };

typedef struct {
    axi_qspi_t *spi;
    uint8_t type;              /* SD_TYPE_* */
    uint8_t last_r1;           /* last command response (diagnostics) */
    uint32_t ocr;
    uint32_t sectors;          /* capacity in 512-byte blocks */
    uint8_t csd[16];
} sd_card_t;

const char *sd_err_text(int err);

int sd_init(sd_card_t *sd, axi_qspi_t *spi);
int sd_read(sd_card_t *sd, uint32_t lba, uint8_t *buf);
int sd_write(sd_card_t *sd, uint32_t lba, const uint8_t *buf);

#endif
