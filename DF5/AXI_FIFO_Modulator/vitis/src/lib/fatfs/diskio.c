/*
 * diskio.c -- FatFs low-level disk I/O for DF5: drive 0 is the microSD card
 * in SPI mode (hal/sd_card). Replaces the example diskio.c of the FatFs archive.
 */
#include "ff.h"
#include "diskio.h"
#include "lib/fatfs/diskio_sd.h"

static sd_card_t *card;
static axi_qspi_t *card_spi;

void diskio_sd_attach(sd_card_t *sd, axi_qspi_t *spi)
{
    card = sd;
    card_spi = spi;
}

DSTATUS disk_status(BYTE pdrv)
{
    if (pdrv != 0u || !card) return STA_NOINIT;
    return (card->type == SD_TYPE_NONE) ? STA_NOINIT : 0u;
}

DSTATUS disk_initialize(BYTE pdrv)
{
    if (pdrv != 0u || !card) return STA_NOINIT;
    if (card->type == SD_TYPE_NONE && sd_init(card, card_spi) != SD_OK) return STA_NOINIT;
    return 0u;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    if (disk_status(pdrv) & STA_NOINIT) return RES_NOTRDY;
    for (; count; count--, sector++, buff += SD_BLOCK)
        if (sd_read(card, (uint32_t)sector, buff) != SD_OK) return RES_ERROR;
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    if (disk_status(pdrv) & STA_NOINIT) return RES_NOTRDY;
    for (; count; count--, sector++, buff += SD_BLOCK)
        if (sd_write(card, (uint32_t)sector, buff) != SD_OK) return RES_ERROR;
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    if (disk_status(pdrv) & STA_NOINIT) return RES_NOTRDY;

    switch (cmd) {
    case CTRL_SYNC:        return RES_OK;      /* sd_write() waits until each block is stored */
    case GET_SECTOR_COUNT: *(LBA_t *)buff = card->sectors; return RES_OK;
    case GET_SECTOR_SIZE:  *(WORD *)buff = SD_BLOCK; return RES_OK;
    case GET_BLOCK_SIZE:   *(DWORD *)buff = 1u; return RES_OK;    /* erase block unknown */
    default:               return RES_PARERR;
    }
}
