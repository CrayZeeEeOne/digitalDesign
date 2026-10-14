/*
 * host_main.c -- run the firmware's viewer on a PC and save every screen.
 *
 * Same code as on the board (vitis/src: source, dsp, app, gfx), with the SPI
 * driver replaced by st7789_emu.c. For each of the 12 views: draw it, keep
 * feeding blocks while the view needs data (live spectrum), then save the
 * panel as out/viewNN.ppm.
 *
 *   host_sim.exe [out_dir]
 */
#include <stdio.h>
#include <stdint.h>
#include "config.h"
#include "gfx/tft.h"
#include "source/src_synth.h"
#include "app/viewer.h"
#include "st7789_emu.h"

static spi_tft_t spi;
static tft_t tft;
static src_synth_t synth;
static viewer_t viewer;
static int16_t iq[CFG_IQ_BLOCK * 2u];

static int feed(void)
{
    iq_source_read(&synth.base, iq, CFG_IQ_BLOCK);
    viewer_process_block(&viewer, iq, CFG_IQ_BLOCK);
    return 1;
}

static int save_ppm(const char *path)
{
    FILE *f = fopen(path, "wb");
    int x, y;

    if (!f) return -1;
    fprintf(f, "P6 %d %d 255\n", tft.w, tft.h);
    for (y = 0; y < tft.h; y++)
        for (x = 0; x < tft.w; x++) {
            uint16_t p = emu_fb[y + tft.y_off][x + tft.x_off];
            fputc((p >> 11) << 3, f);
            fputc(((p >> 5) & 63) << 2, f);
            fputc((p & 31) << 3, f);
        }
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "out";
    int m, blocks = 0;

    tft_init(&tft, &spi, TFT_ROT_90);
    src_synth_init(&synth);
    viewer_init(&viewer);

    while (!viewer_done(&viewer)) blocks += feed();
    printf("capture: %d blocks, %u bursts, panel %ux%u\n",
           blocks, (unsigned)viewer.cap.burst_total, tft.w, tft.h);

    for (m = 0; m < VIEW_COUNT; m++) {
        char path[512];
        int n = 0;

        viewer_set_mode(&viewer, (view_mode_t)m);
        viewer_draw(&viewer, &tft);
        while (viewer_busy(&viewer)) n += feed();

        snprintf(path, sizeof(path), "%s/view%02d.ppm", out, m);
        if (save_ppm(path) != 0) {
            fprintf(stderr, "ERROR: cannot write %s\n", path);
            return 1;
        }
        printf("view %2d: %4d live blocks -> %s\n", m, n, path);
    }
    return 0;
}
