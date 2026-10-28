/*
 * host_main.c -- run the firmware's viewer on a PC and save the screens.
 *
 * Same screens as on the board (vitis/src: app, gfx), with the SPI driver
 * replaced by st7789_emu.c. On the board the PL records the capture; here the C
 * model (source/src_synth -> dsp/capture_model) does, so the screens show the
 * synthetic 2-FSK signal at -250 kHz instead of the RTL generator. Saves every screen at zoom x1 and x4 (bits
 * and FFT also at x16) as out/viewN_xZ.ppm, and checks the decoded bits against the
 * bits the test source actually sent.
 *
 *   host_sim.exe [out_dir]
 */
#include <stdio.h>
#include <stdint.h>
#include "config.h"
#include "gfx/tft.h"
#include "source/src_synth.h"
#include "dsp/capture_model.h"
#include "app/viewer.h"
#include "app/sd_test.h"
#include "st7789_emu.h"

static spi_tft_t spi;
static tft_t tft;
static src_synth_t synth;
static capture_model_t model;
static viewer_t viewer;
static int16_t iq[CFG_IQ_BLOCK * 2u];

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

/* Bit k of a packet as sent by src_synth (see src_synth.c). */
static uint8_t sent_bit(uint32_t sym)
{
    return (uint8_t)((sym < SRC_PREAMBLE) ? (sym & 1u) : (((sym * 0x9E3779B1u) >> 29) & 1u));
}

/* Best alignment of the decoded bits with the sent ones; prints the bit errors. */
static int check_bits(const cap_pkt_t *p, int idx)
{
    uint32_t best_err = 0xFFFFFFFFu, best_off = 0u, off, k;
    uint32_t n = p->nbits;

    for (off = 0u; off < 64u; off++) {
        uint32_t err = 0u, cnt = 0u;
        for (k = 0u; k < n && off + k < SRC_PKT_SYMS; k++, cnt++)
            err += cap_pkt_bit(p, (uint16_t)k) != sent_bit(off + k);
        if (cnt > n / 2u && err < best_err) { best_err = err; best_off = off; }
    }
    printf("packet %d: %u bits decoded, aligned at sent bit %u, %u bit errors\n",
           idx + 1, (unsigned)n, (unsigned)best_off, (unsigned)best_err);
    return (int)best_err;
}

static axi_qspi_t sd_spi;
static sd_card_t sd;
static sd_info_t sd_info;
static uint32_t host_ticks(void) { static uint32_t t; return t += 1000u; }

static int render(int view, int zoom_presses, const char *out)
{
    char path[512];
    int i;

    viewer_set_mode(&viewer, (view_mode_t)view);
    viewer.zoom[view].level = 0u;
    viewer.zoom[view].off = 0u;
    for (i = 0; i < zoom_presses; i++) viewer_key(&viewer, KEY_ZOOM);
    viewer_draw(&viewer, &tft, 1);

    snprintf(path, sizeof(path), "%s/view%d_x%d.ppm", out, view, 1 << zoom_presses);
    if (save_ppm(path) != 0) {
        fprintf(stderr, "ERROR: cannot write %s\n", path);
        return 1;
    }
    printf("view %d x%d -> %s\n", view, 1 << zoom_presses, path);
    return 0;
}

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "out";
    int m, blocks = 0, errors = 0;

    tft_init(&tft, &spi, TFT_ROT_90);
    src_synth_init(&synth);
    viewer_init(&viewer);
    /* NCO: the synthetic carrier (SRC_CARRIER_INC, 16-bit phase) back to 0 Hz;
       bit clock: 2^16 * bitrate / (Fs / 16) */
    capture_model_init(&model, (uint16_t)(-SRC_CARRIER_INC),
                       (uint16_t)(((uint64_t)CFG_BITRATE * 65536u * 16u + CFG_SAMPLE_RATE_HZ / 2u) / CFG_SAMPLE_RATE_HZ));

    while (!capture_model_done(&model)) {
        iq_source_read(&synth.base, iq, CFG_IQ_BLOCK);
        capture_model_block(&model, iq, CFG_IQ_BLOCK);
        blocks++;
    }
    viewer_use_capture(&viewer, &model.d);
    /* SD CARD screen: the card as the stub bus sees it (no card) */
    axi_qspi_init(&sd_spi, 0u);
    sd_test_run(&sd_info, &sd, &sd_spi, host_ticks, 1000000u);
    viewer.sd = &sd_info;

    printf("capture: %d blocks, %u packets, panel %ux%u\n",
           blocks, (unsigned)model.d.npkt, tft.w, tft.h);
    for (m = 0; m < model.d.npkt; m++) {
        const cap_pkt_t *p = &model.d.pkt[m];
        printf("packet %d: samples %u..%u\n", m + 1, (unsigned)p->start, (unsigned)p->end);
        errors += check_bits(p, m);
    }

    for (m = 0; m < VIEW_COUNT; m++) {
        if (render(m, 0, out) || render(m, 2, out)) return 1;
        if ((m == VIEW_BITS || m == VIEW_FFT) && render(m, 4, out)) return 1;
    }
    return errors ? 2 : 0;
}
