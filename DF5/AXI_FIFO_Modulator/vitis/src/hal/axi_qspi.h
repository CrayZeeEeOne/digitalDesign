/*
 * axi_qspi.h -- Xilinx AXI Quad SPI (axi_quad_spi 3.2, standard SPI mode) as a
 * plain byte-wide SPI master with one manually driven slave select.
 *
 * Used for the microSD card. ext_spi_clk = the AXI clock (PG153: in standard mode
 * it must not be slower than the AXI clock); SCK = 100 MHz / C_SCK_RATIO (16) =
 * 6.25 MHz. Register map: Xilinx PG153.
 */
#ifndef AXI_QSPI_H
#define AXI_QSPI_H

#include <stdint.h>

typedef struct {
    uint32_t base;
    uint32_t timeouts;         /* bytes that never came back (should stay 0) */
} axi_qspi_t;

/* Reset the core: master, SPI mode 0, MSB first, manual slave select, deselected. */
void axi_qspi_init(axi_qspi_t *q, uint32_t base);

/* Drive the slave select: 1 = selected (SS low). */
void axi_qspi_select(axi_qspi_t *q, int on);

/* Full-duplex transfer of n bytes; tx == NULL sends 0xFF, rx == NULL drops the input.
   A byte that does not come back in time reads as 0xFF and counts in q->timeouts. */
void axi_qspi_xfer(axi_qspi_t *q, const uint8_t *tx, uint8_t *rx, uint32_t n);

/* One byte out, one byte in. */
uint8_t axi_qspi_byte(axi_qspi_t *q, uint8_t out);

#endif
