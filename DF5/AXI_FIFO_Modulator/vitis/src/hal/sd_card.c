#include "hal/sd_card.h"

#define CLK_ID_DIV    124u        /* 100 MHz / 250 = 400 kHz: identification */
#define CLK_DATA_DIV  1u          /* 100 MHz / 4 = 25 MHz: default speed */
#define SDLY          2u          /* inputs read 20 ns after the rising edge */

#define ST_ERRORS     0xFDF98008u /* card status: error bits of R1 */
#define ST_LOCKED     (1u << 25)

const char *sd_err_text(int err)
{
    switch (err) {
    case SD_OK:          return "OK";
    case SD_ERR_NO_CARD: return "NO CARD (NO ANSWER)";
    case SD_ERR_CMD8:    return "CMD8 FAILED";
    case SD_ERR_ACMD41:  return "ACMD41 TIMEOUT";
    case SD_ERR_CMD58:   return "CMD2/CMD3 FAILED";
    case SD_ERR_CSD:     return "CMD9 (CSD) FAILED";
    case SD_ERR_READ:    return "CMD17 READ FAILED";
    case SD_ERR_WRITE:   return "CMD24 WRITE FAILED";
    case SD_ERR_LOCKED:  return "CARD LOCKED (PASSWORD)";
    case SD_ERR_SELECT:  return "CMD7/ACMD6 FAILED";
    default:             return "NOT INITIALISED";
    }
}

static void delay_us(uint32_t us)
{
    volatile uint32_t i;
    while (us--)
        for (i = 0; i < 20; i++)
            ;
}

/* A command with a 48-bit response (CRC checked); its card status in *st. */
static uint32_t cmd_r1(sd_card_t *sd, uint8_t idx, uint32_t arg, int busy, int data, uint32_t *st)
{
    uint32_t e = sd_host_cmd(sd->host, idx, arg, SDH_RSP_48, busy, 1, data);
    *st = sd_host_resp(sd->host, 0);
    sd->last_r1 = e ? 0xFFu : (uint8_t)(*st >> 8);   /* FF: no answer */
    return e;
}

static uint32_t acmd(sd_card_t *sd, uint8_t idx, uint32_t arg, int crc, uint32_t *st)
{
    uint32_t e = cmd_r1(sd, 55u, (uint32_t)sd->rca << 16, 0, SDH_DATA_NONE, st);
    if (e) return e;
    e = sd_host_cmd(sd->host, idx, arg, SDH_RSP_48, 0, crc, SDH_DATA_NONE);
    *st = sd_host_resp(sd->host, 0);
    return e;
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

uint32_t sd_addr(const sd_card_t *sd, uint32_t lba)
{
    return (sd->type == SD_TYPE_SDHC) ? lba : lba * SD_BLOCK;
}

int sd_init(sd_card_t *sd, sd_host_t *host)
{
    uint32_t st, n, w;
    int err = SD_OK;

    sd->host = host;
    sd->type = SD_TYPE_NONE;
    sd->sectors = 0u;
    sd->ocr = 0u;
    sd->rca = 0u;
    sd->last_r1 = 0xFFu;

    sd_host_stream_stop(host);
    sd_host_clock(host, CLK_ID_DIV, SDLY, 1);
    delay_us(1000);                                  /* >= 74 clocks at 400 kHz */
    sd_host_clock(host, CLK_ID_DIV, SDLY, 0);

    (void)sd_host_cmd(host, 0u, 0u, SDH_RSP_NONE, 0, 0, SDH_DATA_NONE);   /* CMD0: idle */

    /* CMD8: voltage check, answered only by SD v2 cards */
    if (sd_host_cmd(host, 8u, 0x1AAu, SDH_RSP_48, 0, 1, SDH_DATA_NONE) == 0u) {
        if ((sd_host_resp(host, 0) & 0xFFFu) != 0x1AAu) { err = SD_ERR_CMD8; goto out; }
        sd->type = SD_TYPE_V2_SC;
    } else {
        sd->type = SD_TYPE_V1;
    }

    /* ACMD41: start initialisation (HCS for v2); OCR in R3, no CRC; up to ~1 s */
    for (n = 0u; n < 2000u; n++) {
        if (acmd(sd, 41u, (sd->type == SD_TYPE_V2_SC ? 0x40000000u : 0u) | 0x00FF8000u, 0, &st)) {
            err = SD_ERR_NO_CARD;
            goto out;
        }
        if (st & 0x80000000u) break;
        delay_us(500);
    }
    if (!(st & 0x80000000u)) { err = SD_ERR_ACMD41; goto out; }
    sd->ocr = st;
    if (sd->type == SD_TYPE_V2_SC && (st & 0x40000000u)) sd->type = SD_TYPE_SDHC;

    /* CMD2: CID; CMD3: relative address */
    if (sd_host_cmd(host, 2u, 0u, SDH_RSP_136, 0, 0, SDH_DATA_NONE)) { err = SD_ERR_CMD58; goto out; }
    if (cmd_r1(sd, 3u, 0u, 0, SDH_DATA_NONE, &st)) { err = SD_ERR_CMD58; goto out; }
    sd->rca = (uint16_t)(st >> 16);

    /* CMD9: CSD -> capacity (bits 127..0 in the response words 3..0) */
    if (sd_host_cmd(host, 9u, (uint32_t)sd->rca << 16, SDH_RSP_136, 0, 0, SDH_DATA_NONE)) {
        err = SD_ERR_CSD;
        goto out;
    }
    for (w = 0u; w < 4u; w++) {
        uint32_t v = sd_host_resp(host, 3 - (int)w);
        sd->csd[4u * w + 0u] = (uint8_t)(v >> 24);
        sd->csd[4u * w + 1u] = (uint8_t)(v >> 16);
        sd->csd[4u * w + 2u] = (uint8_t)(v >> 8);
        sd->csd[4u * w + 3u] = (uint8_t)v;
    }
    if ((sd->csd[0] >> 6) == 1u) {                  /* CSD v2: (C_SIZE + 1) * 512 KB */
        sd->sectors = (csd_bits(sd->csd, 69u, 22u) + 1u) * 1024u;
    } else {                                        /* CSD v1 */
        uint32_t c_size = csd_bits(sd->csd, 73u, 12u);
        uint32_t mult = csd_bits(sd->csd, 49u, 3u);
        uint32_t bl_len = csd_bits(sd->csd, 83u, 4u);
        sd->sectors = ((c_size + 1u) << (mult + 2u + bl_len)) / SD_BLOCK;
    }

    /* CMD7: select (transfer state), R1b */
    if (cmd_r1(sd, 7u, (uint32_t)sd->rca << 16, 1, SDH_DATA_NONE, &st)) { err = SD_ERR_SELECT; goto out; }
    /* CMD13: status, bit 25 = locked by password */
    if (cmd_r1(sd, 13u, (uint32_t)sd->rca << 16, 0, SDH_DATA_NONE, &st) == 0u && (st & ST_LOCKED)) {
        err = SD_ERR_LOCKED;
        goto out;
    }
    /* ACMD6: 4-bit bus */
    if (acmd(sd, 6u, 2u, 1, &st) || (st & ST_ERRORS)) { err = SD_ERR_SELECT; goto out; }
    if (sd->type != SD_TYPE_SDHC) (void)cmd_r1(sd, 16u, SD_BLOCK, 0, SDH_DATA_NONE, &st);

    sd_host_clock(host, CLK_DATA_DIV, SDLY, 0);

out:
    if (err != SD_OK) sd->type = SD_TYPE_NONE;
    return err;
}

int sd_read(sd_card_t *sd, uint32_t lba, uint8_t *buf)
{
    uint32_t st;

    if (sd->type == SD_TYPE_NONE) return SD_ERR_NOT_INIT;
    if (cmd_r1(sd, 17u, sd_addr(sd, lba), 0, SDH_DATA_READ, &st) || (st & ST_ERRORS)) return SD_ERR_READ;
    sd_host_buf_read(sd->host, buf);
    return SD_OK;
}

int sd_read_multi(sd_card_t *sd, uint32_t lba, uint8_t *buf, uint32_t count)
{
    for (; count; count--, lba++, buf += SD_BLOCK) {
        int e = sd_read(sd, lba, buf);
        if (e) return e;
    }
    return SD_OK;
}

int sd_write(sd_card_t *sd, uint32_t lba, const uint8_t *buf)
{
    uint32_t st;

    if (sd->type == SD_TYPE_NONE) return SD_ERR_NOT_INIT;
    sd_host_buf_write(sd->host, buf);
    if (cmd_r1(sd, 24u, sd_addr(sd, lba), 0, SDH_DATA_WRITE, &st) || (st & ST_ERRORS)) return SD_ERR_WRITE;
    return SD_OK;
}

int sd_write_multi(sd_card_t *sd, uint32_t lba, const uint8_t *buf, uint32_t count)
{
    for (; count; count--, lba++, buf += SD_BLOCK) {
        int e = sd_write(sd, lba, buf);
        if (e) return e;
    }
    return SD_OK;
}
