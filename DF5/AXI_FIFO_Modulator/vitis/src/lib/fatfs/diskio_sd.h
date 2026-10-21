/* diskio_sd.h -- FatFs drive 0 = the microSD card (hal/sd_card). */
#ifndef DISKIO_SD_H
#define DISKIO_SD_H

#include "hal/sd_card.h"

/* Card used by drive 0; disk_initialize() runs sd_init() on it. */
void diskio_sd_attach(sd_card_t *sd, axi_qspi_t *spi);

#endif
