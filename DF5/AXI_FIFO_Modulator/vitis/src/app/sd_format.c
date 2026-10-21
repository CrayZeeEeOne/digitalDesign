#include "app/sd_format.h"
#include "lib/fatfs/ff.h"
#include "lib/fatfs/diskio_sd.h"

#define TEST_FILE "DF5TEST.TXT"

static const char test_text[] = "DF5 MICROSD TEST: WRITTEN BY MICROBLAZE AFTER F_MKFS\r\n";

static BYTE work[4096];        /* f_mkfs work area: bigger = fewer, larger writes */
static FATFS fs;
static FIL fil;

const char *sd_fresult_text(int fr)
{
    static const char *const t[] = {
        "OK", "DISK ERROR", "INTERNAL ERROR", "NOT READY", "NO FILE", "NO PATH",
        "INVALID NAME", "DENIED", "EXIST", "INVALID OBJECT", "WRITE PROTECTED",
        "INVALID DRIVE", "NOT ENABLED", "NO FILESYSTEM", "MKFS ABORTED", "TIMEOUT",
        "LOCKED", "NOT ENOUGH CORE", "TOO MANY OPEN FILES", "INVALID PARAMETER"
    };
    return (fr >= 0 && fr < (int)(sizeof(t) / sizeof(t[0]))) ? t[fr] : "?";
}

static int fail(sd_format_result_t *r, const char *step, FRESULT fr)
{
    r->step = step;
    r->fr = (int)fr;
    return 0;
}

void sd_format_run(sd_format_result_t *r, sd_card_t *sd, axi_qspi_t *spi,
                   uint32_t (*ticks)(void), uint32_t ticks_hz)
{
    MKFS_PARM opt = { FM_FAT32, 0, 0, 0, 0 };
    char back[sizeof(test_text)];
    FRESULT fr;
    UINT n;
    DWORD nclst;
    FATFS *pfs;
    uint32_t t0;
    uint32_t i;

    r->done = 1u;
    r->ok = 0u;
    r->step = "";
    r->fr = 0;
    r->fat_bits = 0u;
    r->free_kb = 0u;

    sd->type = SD_TYPE_NONE;                 /* disk_initialize() starts the card afresh */
    diskio_sd_attach(sd, spi);

    t0 = ticks();
    fr = f_mkfs("", &opt, work, sizeof(work));
    if (fr == FR_MKFS_ABORTED) {             /* too small for FAT32: let FatFs choose */
        opt.fmt = FM_ANY;
        fr = f_mkfs("", &opt, work, sizeof(work));
    }
    r->ms = (ticks() - t0) / (ticks_hz / 1000u);
    if (fr != FR_OK) { fail(r, "MKFS", fr); return; }

    if ((fr = f_mount(&fs, "", 1)) != FR_OK) { fail(r, "MOUNT", fr); return; }
    r->fat_bits = (fs.fs_type == FS_FAT32) ? 32u : (fs.fs_type == FS_FAT16) ? 16u : 12u;
    if (f_getfree("", &nclst, &pfs) == FR_OK)
        r->free_kb = (nclst * pfs->csize) / 2u;

    fr = f_open(&fil, TEST_FILE, FA_CREATE_ALWAYS | FA_WRITE);
    if (fr == FR_OK) fr = f_write(&fil, test_text, sizeof(test_text) - 1u, &n);
    if (fr == FR_OK) fr = f_close(&fil);
    if (fr != FR_OK || n != sizeof(test_text) - 1u) { fail(r, "WRITE", fr); goto out; }

    fr = f_open(&fil, TEST_FILE, FA_READ);
    if (fr == FR_OK) fr = f_read(&fil, back, sizeof(test_text) - 1u, &n);
    if (fr == FR_OK) fr = f_close(&fil);
    if (fr != FR_OK || n != sizeof(test_text) - 1u) { fail(r, "READ", fr); goto out; }

    for (i = 0u; i < sizeof(test_text) - 1u; i++)
        if (back[i] != test_text[i]) { fail(r, "COMPARE", FR_OK); goto out; }

    r->ok = 1u;
out:
    f_unmount("");
}
