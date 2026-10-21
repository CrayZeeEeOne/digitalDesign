/*
 * sd_test.h -- first contact with the microSD card: initialise it, read the
 * MBR and the FAT boot sector, list the root directory, measure the read speed.
 *
 * A diagnostic, read-only FAT16/FAT32 reader (8.3 names only); the real file
 * access will go through FatFs (Block 2 of the task).
 */
#ifndef SD_TEST_H
#define SD_TEST_H

#include <stdint.h>
#include "hal/sd_card.h"

#define SD_TEST_FILES 8

typedef struct {
    int err;                   /* SD_OK or SD_ERR_* of the first failing step */
    const char *step;          /* where it failed: "INIT", "MBR", "BOOT SECTOR", "ROOT DIR" */
    uint8_t type;              /* SD_TYPE_* */
    uint8_t last_r1;
    uint32_t sectors;          /* card capacity, 512-byte blocks */

    uint8_t part_type;         /* MBR partition 1 type (0 = no MBR, FAT starts at block 0) */
    uint32_t part_lba;
    uint8_t fat_bits;          /* 16 or 32, 0 = not FAT */
    char label[12];
    uint32_t cluster_bytes;

    uint8_t nfiles;
    char name[SD_TEST_FILES][13];
    uint32_t size[SD_TEST_FILES];
    uint8_t is_dir[SD_TEST_FILES];

    uint32_t read_kbps;        /* sequential single-block reads, KB/s */
} sd_info_t;

/* ticks(): free-running AXI clock counter, ticks_hz its rate (read speed). */
void sd_test_run(sd_info_t *info, sd_card_t *sd, axi_qspi_t *spi,
                 uint32_t (*ticks)(void), uint32_t ticks_hz);

#endif
