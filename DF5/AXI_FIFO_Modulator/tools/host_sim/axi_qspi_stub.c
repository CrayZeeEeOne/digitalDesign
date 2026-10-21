/* axi_qspi_stub.c -- host build: an SPI bus with no card on it (MISO always high). */
#include "hal/axi_qspi.h"

void axi_qspi_init(axi_qspi_t *q, uint32_t base) { q->base = base; q->timeouts = 0u; }
void axi_qspi_select(axi_qspi_t *q, int on) { (void)q; (void)on; }

void axi_qspi_xfer(axi_qspi_t *q, const uint8_t *tx, uint8_t *rx, uint32_t n)
{
    (void)q; (void)tx;
    while (n--) if (rx) *rx++ = 0xFFu;
}

uint8_t axi_qspi_byte(axi_qspi_t *q, uint8_t out) { (void)q; (void)out; return 0xFFu; }
