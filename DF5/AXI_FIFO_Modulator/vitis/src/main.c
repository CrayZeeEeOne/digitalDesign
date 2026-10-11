#include <stdint.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "spi_tft.h"
#include "tft.h"
#include "graph_viewer.h"
#include "system_ctrl.h"

#ifndef SPI_TFT_BASE
#define SPI_TFT_BASE   XPAR_SPI_TFT_CTRL_0_S_AXI_BASEADDR
#endif
#ifndef SYS_CTRL_BASE
#if defined(XPAR_SYSTEM_CTRL_TOP_0_S_AXI_BASEADDR)
#define SYS_CTRL_BASE  XPAR_SYSTEM_CTRL_TOP_0_S_AXI_BASEADDR
#elif defined(XPAR_SYSTEM_CTRL_0_S_AXI_BASEADDR)
#define SYS_CTRL_BASE  XPAR_SYSTEM_CTRL_0_S_AXI_BASEADDR
#else
#define SYS_CTRL_BASE  0u
#endif
#endif
#ifndef ACLK_HZ
#define ACLK_HZ        100000000u
#endif
#ifndef SCLK_HZ
#define SCLK_HZ        12500000u
#endif

#define IQ_BLOCK       1024u

static spi_tft_t spi;
static tft_t tft;
static system_ctrl_t sys;
static graph_viewer_t viewer;

static void gen_iq_block(int16_t *iq, uint32_t n, uint32_t *phase, uint32_t *sym_phase, uint32_t *burst_gate)
{
    uint32_t k;
    for (k = 0; k < n; k++) {
        int bit;
        int32_t acc;
        int16_t s;
        int16_t c;
        int16_t i;
        int16_t q;

        *sym_phase += 19200u;
        if (*sym_phase >= 4500000u) {
            *sym_phase -= 4500000u;
            *burst_gate += 1u;
        }

        bit = ((*burst_gate / 96u) & 1u) ? 1 : -1;
        if (((*burst_gate / 640u) & 1u) == 0u)
            bit = 0;

        acc = (int32_t)(*phase + (uint32_t)(bit * 410));
        *phase = (uint32_t)acc;

        s = (int16_t)(((*phase >> 8) & 0x80u) ? -1800 : 1800);
        c = (int16_t)(((*phase >> 9) & 0x80u) ? -1800 : 1800);

        i = (int16_t)(c + ((int32_t)(k & 63u) - 32) * 2);
        q = (int16_t)(s + ((int32_t)((k + 17u) & 63u) - 32) * 2);

        iq[2u * k] = i;
        iq[2u * k + 1u] = q;
    }
}

int main(void)
{
    uint32_t events;
    int16_t iq[IQ_BLOCK * 2u];
    uint32_t phase = 0;
    uint32_t sym_phase = 0;
    uint32_t burst_gate = 0;
    viewer_cfg_t cfg;

    xil_printf("\r\n=== DF5 LCD Graph Viewer ===\r\n");

    if (spi_tft_init(&spi, SPI_TFT_BASE, ACLK_HZ, SCLK_HZ) != 0) {
        xil_printf("ERROR: SPI TFT core not found\r\n");
        return -1;
    }

    tft_init(&tft, &spi, TFT_ROT_0);
    spi_tft_backlight(&spi, 1);

    system_ctrl_init(&sys, SYS_CTRL_BASE);

    cfg.sample_rate_hz = 4500000u;
    cfg.center_freq_hz = 868500000u;
    cfg.channel_freq_hz = 868250000u;
    cfg.bitrate = 19200u;

    graph_viewer_init(&viewer, &cfg);

    xil_printf("KEY1 -> next view, KEY2 -> previous view\r\n");
    xil_printf("Center frequency: 868.5 MHz\r\n");

    while (1) {
        gen_iq_block(iq, IQ_BLOCK, &phase, &sym_phase, &burst_gate);
        graph_viewer_process_block(&viewer, iq, IQ_BLOCK);

        events = system_ctrl_get_press_events(&sys);
        if (events & SYS_BTN1_MASK)
            graph_viewer_next(&viewer);
        if (events & SYS_BTN2_MASK)
            graph_viewer_prev(&viewer);
        if (events)
            system_ctrl_clear_press_events(&sys, events);

        graph_viewer_draw(&viewer, &tft);
        spi_tft_flush(&spi);
    }

    return 0;
}
