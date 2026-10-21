#include "hal/sd_card.h"

#define R1_IDLE       0x01u
#define R1_ILLEGAL    0x04u
#define TOKEN_DATA    0xFEu

const char *sd_err_text(int err)
{
    switch (err) {
    case SD_OK:          return "OK";
    case SD_ERR_NO_CARD: return "NO CARD (NO ANSWER TO CMD0)";
    case SD_ERR_CMD8:    return "CMD8 FAILED";
    case SD_ERR_ACMD41:  return "ACMD41 TIMEOUT";
    case SD_ERR_CMD58:   return "CMD58 (OCR) FAILED";
    case SD_ERR_CSD:     return "CMD9 (CSD) FAILED";
    case SD_ERR_READ:    return "CMD17 READ FAILED";
    case SD_ERR_WRITE:   return "CMD24 WRITE FAILED";
    case SD_ERR_LOCKED:  return "CARD LOCKED (PASSWORD)";
    default:             return "NOT INITIALISED";
    }
}

static uint8_t xchg(sd_card_t *sd, uint8_t b) { return axi_qspi_byte(sd->spi, b); }

static void deselect(sd_card_t *sd)
{
    axi_qspi_select(sd->spi, 0);
    xchg(sd, 0xFFu);            /* the card releases MISO on the next clock */
}

/* Wait until the card stops signalling busy (MISO high); a write may take ~0.5 s. */
static int wait_ready(sd_card_t *sd)
{
    uint32_t n;
    for (n = 0u; n < 500000u; n++)
        if (xchg(sd, 0xFFu) == 0xFFu) return 1;
    return 0;
}

/* Send a command, return R1 (0xFF = no answer). Leaves the card selected. */
static uint8_t command(sd_card_t *sd, uint8_t cmd, uint32_t arg)
{
    uint8_t frame[6];
    uint8_t r1 = 0xFFu;
    uint8_t n;

    if (cmd & 0x80u) {          /* ACMDn = CMD55 + CMDn */
        cmd &= 0x7Fu;
        r1 = command(sd, 55u, 0u);
        if (r1 > R1_IDLE) return r1;
    }

    deselect(sd);
    axi_qspi_select(sd->spi, 1);
    if (cmd != 0u) wait_ready(sd);

    frame[0] = (uint8_t)(0x40u | cmd);
    frame[1] = (uint8_t)(arg >> 24);
    frame[2] = (uint8_t)(arg >> 16);
    frame[3] = (uint8_t)(arg >> 8);
    frame[4] = (uint8_t)arg;
    frame[5] = (cmd == 0u) ? 0x95u : (cmd == 8u) ? 0x87u : 0x01u;   /* CRC needed only before CMD59 */
    axi_qspi_xfer(sd->spi, frame, 0, 6u);

    for (n = 0u; n < 10u; n++) {
        r1 = xchg(sd, 0xFFu);
        if (!(r1 & 0x80u)) break;
    }
    sd->last_r1 = r1;
    return r1;
}

/* Read a data block of len bytes after a command (data token + data + CRC). */
static int read_data(sd_card_t *sd, uint8_t *buf, uint32_t len)
{
    uint32_t n;
    uint8_t t = 0xFFu;

    for (n = 0u; n < 100000u; n++) {
        t = xchg(sd, 0xFFu);
        if (t != 0xFFu) break;
    }
    if (t != TOKEN_DATA) return 0;
    axi_qspi_xfer(sd->spi, 0, buf, len);
    xchg(sd, 0xFFu);            /* CRC, not checked */
    xchg(sd, 0xFFu);
    return 1;
}

static uint32_t csd_bits(const uint8_t *csd, uint32_t msb, uint32_t width)
{
    uint32_t v = 0u, i;
    for (i = 0u; i < width; i++) {
        uint32_t bit = msb - i;                       /* bit 127 = MSB of csd[0] */
        v = (v << 1) | ((csd[15u - bit / 8u] >> (bit % 8u)) & 1u);
    }
    return v;
}

int sd_init(sd_card_t *sd, axi_qspi_t *spi)
{
    uint8_t r1, r7[4];
    uint32_t n;
    int err = SD_OK;

    sd->spi = spi;
    sd->type = SD_TYPE_NONE;
    sd->sectors = 0u;
    sd->ocr = 0u;

    axi_qspi_select(spi, 0);
    for (n = 0u; n < 10u; n++) xchg(sd, 0xFFu);     /* >= 74 clocks with CS high */

    /* CMD0: go idle (SPI mode) */
    for (n = 0u; n < 10u; n++) {
        r1 = command(sd, 0u, 0u);
        if (r1 == R1_IDLE) break;
    }
    if (r1 != R1_IDLE) { err = SD_ERR_NO_CARD; goto out; }

    /* CMD8: voltage check, tells SD v2 from v1 */
    r1 = command(sd, 8u, 0x1AAu);
    if (r1 == R1_IDLE) {
        axi_qspi_xfer(spi, 0, r7, 4u);
        if (r7[2] != 0x01u || r7[3] != 0xAAu) { err = SD_ERR_CMD8; goto out; }
        sd->type = SD_TYPE_V2_SC;
    } else if (r1 & R1_ILLEGAL) {
        sd->type = SD_TYPE_V1;
    } else {
        err = SD_ERR_CMD8; goto out;
    }

    /* ACMD41: start initialisation, HCS set for v2 cards; up to ~1 s */
    for (n = 0u; n < 40000u; n++) {
        r1 = command(sd, 0x80u | 41u, (sd->type == SD_TYPE_V2_SC) ? 0x40000000u : 0u);
        if (r1 == 0u) break;
    }
    if (r1 != 0u) { err = SD_ERR_ACMD41; goto out; }

    /* CMD58: OCR, CCS bit = block addressing (SDHC/SDXC) */
    if (sd->type == SD_TYPE_V2_SC) {
        if (command(sd, 58u, 0u) != 0u) { err = SD_ERR_CMD58; goto out; }
        axi_qspi_xfer(spi, 0, r7, 4u);
        sd->ocr = ((uint32_t)r7[0] << 24) | ((uint32_t)r7[1] << 16) | ((uint32_t)r7[2] << 8) | r7[3];
        if (sd->ocr & 0x40000000u) sd->type = SD_TYPE_SDHC;
    }
    if (sd->type != SD_TYPE_SDHC) command(sd, 16u, SD_BLOCK);   /* 512-byte blocks */

    /* CMD13: R2, second byte bit 0 = card is locked */
    if (command(sd, 13u, 0u) == 0u && (xchg(sd, 0xFFu) & 0x01u)) { err = SD_ERR_LOCKED; goto out; }

    /* CMD9: CSD -> capacity */
    if (command(sd, 9u, 0u) != 0u || !read_data(sd, sd->csd, 16u)) { err = SD_ERR_CSD; goto out; }
    if ((sd->csd[0] >> 6) == 1u) {                  /* CSD v2: (C_SIZE + 1) * 512 KB */
        sd->sectors = (csd_bits(sd->csd, 69u, 22u) + 1u) * 1024u;
    } else {                                        /* CSD v1 */
        uint32_t c_size = csd_bits(sd->csd, 73u, 12u);
        uint32_t mult = csd_bits(sd->csd, 49u, 3u);
        uint32_t bl_len = csd_bits(sd->csd, 83u, 4u);
        sd->sectors = ((c_size + 1u) << (mult + 2u + bl_len)) / SD_BLOCK;
    }

out:
    deselect(sd);
    if (err != SD_OK) sd->type = SD_TYPE_NONE;
    return err;
}

int sd_read(sd_card_t *sd, uint32_t lba, uint8_t *buf)
{
    int ok;

    if (sd->type == SD_TYPE_NONE) return SD_ERR_NOT_INIT;
    ok = command(sd, 17u, (sd->type == SD_TYPE_SDHC) ? lba : lba * SD_BLOCK) == 0u
         && read_data(sd, buf, SD_BLOCK);
    deselect(sd);
    return ok ? SD_OK : SD_ERR_READ;
}

int sd_write(sd_card_t *sd, uint32_t lba, const uint8_t *buf)
{
    uint8_t resp;
    int ok = 0;

    if (sd->type == SD_TYPE_NONE) return SD_ERR_NOT_INIT;
    if (command(sd, 24u, (sd->type == SD_TYPE_SDHC) ? lba : lba * SD_BLOCK) == 0u) {
        xchg(sd, 0xFFu);                            /* one byte gap before the token */
        xchg(sd, TOKEN_DATA);
        axi_qspi_xfer(sd->spi, buf, 0, SD_BLOCK);
        xchg(sd, 0xFFu);                            /* CRC, ignored in SPI mode */
        xchg(sd, 0xFFu);
        resp = xchg(sd, 0xFFu);                     /* data response: xxx0 0101 = accepted */
        ok = ((resp & 0x1Fu) == 0x05u) && wait_ready(sd);
    }
    deselect(sd);
    return ok ? SD_OK : SD_ERR_WRITE;
}
