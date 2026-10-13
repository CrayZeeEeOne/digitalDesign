#include <stdint.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "spi_tft.h"
#include "tft.h"
#include "graph_viewer.h"
#include "system_ctrl.h"
#include "dsp_tables.h"

#ifndef SPI_TFT_BASE
#if defined(XPAR_SPI_TFT_CTRL_0_S_AXI_BASEADDR)
#define SPI_TFT_BASE   XPAR_SPI_TFT_CTRL_0_S_AXI_BASEADDR
#elif defined(XPAR_TFT_TOP_0_BASEADDR)
#define SPI_TFT_BASE   XPAR_TFT_TOP_0_BASEADDR
#else
#define SPI_TFT_BASE   0u
#endif
#endif
#ifndef SYS_CTRL_BASE
#if defined(XPAR_SYSTEM_CTRL_TOP_0_S_AXI_BASEADDR)
#define SYS_CTRL_BASE  XPAR_SYSTEM_CTRL_TOP_0_S_AXI_BASEADDR
#elif defined(XPAR_SYSTEM_CTRL_TOP_0_BASEADDR)
#define SYS_CTRL_BASE  XPAR_SYSTEM_CTRL_TOP_0_BASEADDR
#elif defined(XPAR_SYSTEM_CTRL_0_S_AXI_BASEADDR)
#define SYS_CTRL_BASE  XPAR_SYSTEM_CTRL_0_S_AXI_BASEADDR
#elif defined(XPAR_SYSTEM_CTRL_0_BASEADDR)
#define SYS_CTRL_BASE  XPAR_SYSTEM_CTRL_0_BASEADDR
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

#define IQ_BLOCK       256u

static spi_tft_t spi;
static tft_t tft;
static system_ctrl_t sys;
static graph_viewer_t viewer;

/* Test source: 2-FSK packets at channel_freq (-250 kHz from center), noise in gaps. */
#define SRC_CARRIER_INC  (-3641)   /* -250 kHz at 4.5 MS/s, 16-bit phase */
#define SRC_DEV_INC      728       /* +-50 kHz deviation */
#define SRC_AMP          3000
#define SRC_PKT_SYMS     192u
#define SRC_GAP_SYMS     128u
#define SRC_PREAMBLE     32u

static int16_t src_sin(uint16_t phase)
{
    uint16_t idx = (phase >> 6) & 1023u;
    uint16_t o = idx & 255u;

    switch (idx >> 8) {
    case 0: return  dsp_sin_q15[o];
    case 1: return  dsp_sin_q15[256u - o];
    case 2: return -dsp_sin_q15[o];
    default: return -dsp_sin_q15[256u - o];
    }
}

static void gen_iq_block(int16_t *iq, uint32_t n, uint32_t *phase, uint32_t *sym_phase, uint32_t *burst_gate)
{
    static uint32_t lfsr = 0x12345678u;
    uint32_t k;

    for (k = 0; k < n; k++) {
        uint32_t sym = *burst_gate % (SRC_PKT_SYMS + SRC_GAP_SYMS);
        int16_t i = 0;
        int16_t q = 0;

        *sym_phase += 19200u;
        if (*sym_phase >= 4500000u) {
            *sym_phase -= 4500000u;
            *burst_gate += 1u;
        }

        if (sym < SRC_PKT_SYMS) {
            int bit = (sym < SRC_PREAMBLE) ? (int)(sym & 1u)
                                           : (int)(((sym * 0x9E3779B1u) >> 29) & 1u);
            uint16_t ph;

            *phase += (uint32_t)(SRC_CARRIER_INC + (bit ? SRC_DEV_INC : -SRC_DEV_INC));
            ph = (uint16_t)*phase;
            i = (int16_t)(((int32_t)src_sin((uint16_t)(ph + 16384u)) * SRC_AMP) >> 15);
            q = (int16_t)(((int32_t)src_sin(ph) * SRC_AMP) >> 15);
        }

        lfsr ^= lfsr << 13;
        lfsr ^= lfsr >> 17;
        lfsr ^= lfsr << 5;
        i = (int16_t)(i + (int16_t)(lfsr & 255u) - 128);
        q = (int16_t)(q + (int16_t)((lfsr >> 8) & 255u) - 128);

        iq[2u * k] = i;
        iq[2u * k + 1u] = q;
    }
}

int main(void)
{
    uint32_t events;
    uint32_t edge_raw;
    uint32_t btn_raw;
    uint32_t btn_raw_prev = 0u;
    static int16_t iq[IQ_BLOCK * 2u];
    uint32_t phase = 0;
    uint32_t sym_phase = 0;
    uint32_t burst_gate = 0;
    uint32_t blocks = 0;
    int redraw = 1;
    viewer_cfg_t cfg;

    xil_printf("\r\n=== DF5 LCD Graph Viewer ===\r\n");

    if (spi_tft_init(&spi, SPI_TFT_BASE, ACLK_HZ, SCLK_HZ) != 0) {
        xil_printf("ERROR: SPI TFT core not found\r\n");
        return -1;
    }

    tft_init(&tft, &spi, TFT_ROT_90);
    spi_tft_backlight(&spi, 1);

    system_ctrl_init(&sys, SYS_CTRL_BASE);

    cfg.sample_rate_hz = 4500000u;
    cfg.center_freq_hz = 868500000u;
    cfg.channel_freq_hz = 868250000u;
    cfg.bitrate = 19200u;

    graph_viewer_init(&viewer, &cfg);

    xil_printf("KEY1 -> next view, KEY2 -> previous view\r\n");
    xil_printf("Center frequency: 868.5 MHz\r\n");

    /*
     * Record one capture, then the picture stays still and is redrawn only on a key press.
     * Spectrum views keep taking new blocks until their plot is drawn (see graph_viewer.h).
     */
    while (1) {
        if (graph_viewer_busy(&viewer)) {
            int was_done = graph_viewer_done(&viewer);

            gen_iq_block(iq, IQ_BLOCK, &phase, &sym_phase, &burst_gate);
            graph_viewer_process_block(&viewer, iq, IQ_BLOCK);
            if (!was_done && (graph_viewer_done(&viewer) || (++blocks % 64u) == 0u))
                redraw = 1;
        }

        events = system_ctrl_get_press_events(&sys);

        btn_raw = system_ctrl_get_buttons_raw(&sys);
        edge_raw = (btn_raw & ~btn_raw_prev) & (SYS_BTN1_MASK | SYS_BTN2_MASK);
        btn_raw_prev = btn_raw;

        events |= edge_raw;

        if (events & SYS_BTN1_MASK)
            graph_viewer_next(&viewer);
        if (events & SYS_BTN2_MASK)
            graph_viewer_prev(&viewer);
        if (events) {
            system_ctrl_clear_press_events(&sys, events);
            redraw = 1;
        }

        if (redraw) {
            graph_viewer_draw(&viewer, &tft);
            spi_tft_flush(&spi);
            redraw = 0;
        }
    }

    return 0;
}
