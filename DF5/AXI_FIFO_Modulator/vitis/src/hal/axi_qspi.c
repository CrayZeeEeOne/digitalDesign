#include "hal/axi_qspi.h"
#include "xil_io.h"

/* PG153 register map */
#define QSPI_SRR     0x40u     /* software reset: write 0x0A */
#define QSPI_SPICR   0x60u     /* control */
#define QSPI_SPISR   0x64u     /* status */
#define QSPI_DTR     0x68u     /* data transmit (TX FIFO) */
#define QSPI_DRR     0x6Cu     /* data receive (RX FIFO) */
#define QSPI_SSR     0x70u     /* slave select, active low */

#define CR_SPE        (1u << 1)
#define CR_MASTER     (1u << 2)
#define CR_TXRST      (1u << 5)
#define CR_RXRST      (1u << 6)
#define CR_MANUAL_SS  (1u << 7)
#define CR_INHIBIT    (1u << 8)

#define SR_RX_EMPTY   (1u << 0)

#define FIFO_DEPTH    16u
#define RX_POLLS      20000u   /* >> one byte at 6.25 MHz (~1.3 us) */

static inline uint32_t rd(const axi_qspi_t *q, uint32_t r) { return Xil_In32(q->base + r); }
static inline void wr(const axi_qspi_t *q, uint32_t r, uint32_t v) { Xil_Out32(q->base + r, v); }

void axi_qspi_init(axi_qspi_t *q, uint32_t base)
{
    volatile uint32_t settle;

    q->base = base;
    q->timeouts = 0u;
    wr(q, QSPI_SRR, 0x0Au);
    for (settle = 0u; settle < 1000u; settle++)   /* let the soft reset finish */
        ;
    wr(q, QSPI_SSR, 0xFFFFFFFFu);
    wr(q, QSPI_SPICR, CR_SPE | CR_MASTER | CR_MANUAL_SS | CR_TXRST | CR_RXRST | CR_INHIBIT);
    wr(q, QSPI_SPICR, CR_SPE | CR_MASTER | CR_MANUAL_SS);
}

void axi_qspi_select(axi_qspi_t *q, int on)
{
    wr(q, QSPI_SSR, on ? 0xFFFFFFFEu : 0xFFFFFFFFu);
}

void axi_qspi_xfer(axi_qspi_t *q, const uint8_t *tx, uint8_t *rx, uint32_t n)
{
    while (n) {
        uint32_t chunk = (n > FIFO_DEPTH) ? FIFO_DEPTH : n;
        uint32_t i;

        for (i = 0u; i < chunk; i++) wr(q, QSPI_DTR, tx ? tx[i] : 0xFFu);
        for (i = 0u; i < chunk; i++) {
            uint8_t b = 0xFFu;
            uint32_t polls = 0u;
            while ((rd(q, QSPI_SPISR) & SR_RX_EMPTY) && ++polls < RX_POLLS)
                ;
            if (polls < RX_POLLS) b = (uint8_t)rd(q, QSPI_DRR);
            else q->timeouts++;
            if (rx) rx[i] = b;
        }
        if (tx) tx += chunk;
        if (rx) rx += chunk;
        n -= chunk;
    }
}

uint8_t axi_qspi_byte(axi_qspi_t *q, uint8_t out)
{
    uint8_t in;
    axi_qspi_xfer(q, &out, &in, 1u);
    return in;
}
