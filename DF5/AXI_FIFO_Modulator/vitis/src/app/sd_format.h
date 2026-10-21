/*
 * sd_format.h -- format the microSD card with FatFs and prove it works:
 * f_mkfs (FAT32, one MBR partition) -> f_mount -> write DF5TEST.TXT ->
 * read it back and compare. ERASES THE WHOLE CARD.
 */
#ifndef SD_FORMAT_H
#define SD_FORMAT_H

#include <stdint.h>
#include "hal/sd_card.h"

typedef struct {
    uint8_t done;              /* a format was attempted */
    uint8_t ok;                /* every step passed */
    const char *step;          /* first failing step: "MKFS", "MOUNT", "WRITE", "READ", "COMPARE" */
    int fr;                    /* FatFs FRESULT of that step */
    uint8_t fat_bits;          /* 12, 16 or 32 after formatting */
    uint32_t free_kb;          /* free space after formatting */
    uint32_t ms;               /* time spent in f_mkfs */
} sd_format_result_t;

void sd_format_run(sd_format_result_t *r, sd_card_t *sd, axi_qspi_t *spi,
                   uint32_t (*ticks)(void), uint32_t ticks_hz);

const char *sd_fresult_text(int fr);

#endif
