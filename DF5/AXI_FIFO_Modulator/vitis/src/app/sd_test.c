#include "app/sd_test.h"

#define SPEED_BLOCKS 64u

static uint8_t blk[SD_BLOCK];

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

/* A FAT boot sector: jump instruction + 512-byte sectors + signature. */
static int is_fat_boot(const uint8_t *b)
{
    return (b[0] == 0xEBu || b[0] == 0xE9u) && le16(&b[11]) == 512u && b[510] == 0x55u && b[511] == 0xAAu;
}

static void copy_name(char *dst, const uint8_t *src, int n)
{
    int i, end = n;
    while (end > 0 && src[end - 1] == ' ') end--;
    for (i = 0; i < end; i++) dst[i] = (char)src[i];
    dst[end] = '\0';
}

static int fail(sd_info_t *info, const char *step, int err)
{
    info->step = step;
    info->err = err;
    return err;
}

/* Root directory entries in one sector; returns 1 at the end-of-directory marker. */
static int scan_dir(sd_info_t *info, const uint8_t *b)
{
    uint16_t off;

    for (off = 0u; off < SD_BLOCK; off += 32u) {
        const uint8_t *e = &b[off];
        uint8_t attr = e[11];

        if (e[0] == 0x00u) return 1;
        if (e[0] == 0xE5u || attr == 0x0Fu) continue;          /* deleted / long-name piece */
        if (attr & 0x08u) { copy_name(info->label, e, 11); continue; }   /* volume label */
        if (info->nfiles < SD_TEST_FILES) {
            char *n = info->name[info->nfiles];
            copy_name(n, e, 8);
            if (e[8] != ' ') {
                char *p = n;
                while (*p) p++;
                *p++ = '.';
                copy_name(p, &e[8], 3);
            }
            info->size[info->nfiles] = le32(&e[28]);
            info->is_dir[info->nfiles] = (uint8_t)((attr & 0x10u) != 0u);
            info->nfiles++;
        }
    }
    return 0;
}

void sd_test_run(sd_info_t *info, sd_card_t *sd, axi_qspi_t *spi,
                 uint32_t (*ticks)(void), uint32_t ticks_hz)
{
    uint32_t n, boot, fat_start, fat_size, data_start, root, root_sectors = 0u, spc;
    uint32_t t0, dt;
    int err;

    for (n = 0u; n < sizeof(*info); n++) ((uint8_t *)info)[n] = 0u;
    info->step = "";

    err = sd_init(sd, spi);
    info->type = sd->type;
    info->last_r1 = sd->last_r1;
    info->sectors = sd->sectors;
    if (err) { fail(info, "INIT", err); return; }

    /* block 0: MBR with a partition table, or directly a FAT boot sector */
    if ((err = sd_read(sd, 0u, blk)) != SD_OK) { fail(info, "MBR", err); return; }
    if (is_fat_boot(blk)) {
        boot = 0u;
    } else {
        info->part_type = blk[446 + 4];
        info->part_lba = le32(&blk[446 + 8]);
        boot = info->part_lba;
        if ((err = sd_read(sd, boot, blk)) != SD_OK) { fail(info, "BOOT SECTOR", err); return; }
        if (!is_fat_boot(blk)) { fail(info, "BOOT SECTOR", SD_OK); return; }   /* not FAT */
    }

    spc = blk[13];
    info->cluster_bytes = spc * SD_BLOCK;
    fat_start = boot + le16(&blk[14]);
    fat_size = le16(&blk[22]) ? le16(&blk[22]) : le32(&blk[36]);
    data_start = fat_start + blk[16] * fat_size;
    if (le16(&blk[22]) == 0u) {                                      /* FAT32 */
        info->fat_bits = 32u;
        copy_name(info->label, &blk[71], 11);
        root = data_start + (le32(&blk[44]) - 2u) * spc;            /* first cluster of the root */
        root_sectors = spc;
    } else {                                                         /* FAT16 */
        info->fat_bits = 16u;
        copy_name(info->label, &blk[43], 11);
        root = data_start;
        root_sectors = (le16(&blk[17]) * 32u + SD_BLOCK - 1u) / SD_BLOCK;
    }

    for (n = 0u; n < root_sectors; n++) {
        if ((err = sd_read(sd, root + n, blk)) != SD_OK) { fail(info, "ROOT DIR", err); return; }
        if (scan_dir(info, blk)) break;
    }

    /* read speed: SPEED_BLOCKS single-block reads from the start of the volume */
    t0 = ticks();
    for (n = 0u; n < SPEED_BLOCKS; n++)
        if (sd_read(sd, boot + n, blk) != SD_OK) break;
    dt = ticks() - t0;
    if (n == SPEED_BLOCKS && dt >= 100u)          /* KB read * ticks per second / ticks */
        info->read_kbps = ((SPEED_BLOCKS * SD_BLOCK / 1024u) * (ticks_hz / 100u)) / (dt / 100u);
}
