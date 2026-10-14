/*============================================================================
 * spi_tft.c -- реалізація низького рівня.
 *==========================================================================*/
#include "hal/spi_tft.h"
#include "xil_io.h"

static inline void wr(spi_tft_t *d, uint32_t off, uint32_t v)
{
    Xil_Out32(d->base + off, v);
}

static inline uint32_t rd(spi_tft_t *d, uint32_t off)
{
    return Xil_In32(d->base + off);
}

/* Груба затримка. Для bring-up достатньо; за наявності таймера -- замінити. */
static void delay_ms(uint32_t ms)
{
    volatile uint32_t i;
    while (ms--)
        for (i = 0; i < 20000; i++)
            ;
}

/*--------------------------------------------------------------------------*/
int spi_tft_init(spi_tft_t *dev, uint32_t base, uint32_t aclk_hz,
                 uint32_t sclk_hz)
{
    uint32_t div;

    dev->base    = base;
    dev->aclk_hz = aclk_hz;

    /* Перша перевірка: чи взагалі відповідає блок на шині. */
    if (rd(dev, SPI_TFT_REG_ID) != SPI_TFT_ID_EXPECTED)
        return -1;

    /* f_sclk = f_aclk / (2*(div+1))  ->  div = f_aclk/(2*f_sclk) - 1 */
    if (sclk_hz == 0)
        return -2;
    div = aclk_hz / (2u * sclk_hz);
    div = (div == 0) ? 0 : (div - 1);
    if (div > 0xFFFF)
        div = 0xFFFF;
    wr(dev, SPI_TFT_REG_CLKDIV, div);

    /* Вмикаємо ядро, CS автоматичний, дисплей поки в скиді. */
    wr(dev, SPI_TFT_REG_CTRL, SPI_TFT_CTRL_ENABLE | SPI_TFT_CTRL_CS_AUTO);
    return 0;
}

/*--------------------------------------------------------------------------*/
void spi_tft_hw_reset(spi_tft_t *dev)
{
    uint32_t ctrl = rd(dev, SPI_TFT_REG_CTRL);

    wr(dev, SPI_TFT_REG_CTRL, ctrl & ~SPI_TFT_CTRL_RST_N);
    delay_ms(10);
    wr(dev, SPI_TFT_REG_CTRL, ctrl | SPI_TFT_CTRL_RST_N);
    delay_ms(120);                 /* ST7789 потребує паузи після скиду */
}

/*--------------------------------------------------------------------------*/
void spi_tft_backlight(spi_tft_t *dev, int on)
{
    uint32_t ctrl = rd(dev, SPI_TFT_REG_CTRL);

    if (on)
        ctrl |= SPI_TFT_CTRL_BLK;
    else
        ctrl &= ~SPI_TFT_CTRL_BLK;

    wr(dev, SPI_TFT_REG_CTRL, ctrl);
}

/*--------------------------------------------------------------------------*/
void spi_tft_flush(spi_tft_t *dev)
{
    uint32_t st;
    do {
        st = rd(dev, SPI_TFT_REG_STATUS);
    } while ((st & SPI_TFT_ST_BUSY) || !(st & SPI_TFT_ST_TX_EMPTY));
}

/*--------------------------------------------------------------------------*/
static void set_dc(spi_tft_t *dev, int dc)
{
    uint32_t ctrl = rd(dev, SPI_TFT_REG_CTRL);
    uint32_t want = dc ? (ctrl | SPI_TFT_CTRL_DC) : (ctrl & ~SPI_TFT_CTRL_DC);

    if (want == ctrl)
        return;

    /* DC перемикається тільки між байтами -- інакше поточний байт
       приїде з неправильним типом. */
    spi_tft_flush(dev);
    wr(dev, SPI_TFT_REG_CTRL, want);
}

/*--------------------------------------------------------------------------*/
void spi_tft_put(spi_tft_t *dev, int dc, uint8_t byte)
{
    set_dc(dev, dc);
    while (rd(dev, SPI_TFT_REG_STATUS) & SPI_TFT_ST_TX_FULL)
        ;
    wr(dev, SPI_TFT_REG_TXDATA, byte);
}

/*--------------------------------------------------------------------------*/
void spi_tft_write(spi_tft_t *dev, int dc, const uint8_t *buf, uint32_t len)
{
    uint32_t i;

    set_dc(dev, dc);
    for (i = 0; i < len; i++) {
        while (rd(dev, SPI_TFT_REG_STATUS) & SPI_TFT_ST_TX_FULL)
            ;
        wr(dev, SPI_TFT_REG_TXDATA, buf[i]);
    }
}

/*--------------------------------------------------------------------------*/
void spi_tft_cmd(spi_tft_t *dev, uint8_t cmd, const uint8_t *args, uint32_t n)
{
    spi_tft_put(dev, 0, cmd);
    if (n)
        spi_tft_write(dev, 1, args, n);
}

/*--------------------------------------------------------------------------*/
void spi_tft_repeat16(spi_tft_t *dev, uint16_t value, uint32_t count)
{
    uint8_t hi = (uint8_t)(value >> 8);
    uint8_t lo = (uint8_t)(value & 0xFF);

    set_dc(dev, 1);
    while (count--) {
        while (rd(dev, SPI_TFT_REG_STATUS) & SPI_TFT_ST_TX_FULL)
            ;
        wr(dev, SPI_TFT_REG_TXDATA, hi);
        while (rd(dev, SPI_TFT_REG_STATUS) & SPI_TFT_ST_TX_FULL)
            ;
        wr(dev, SPI_TFT_REG_TXDATA, lo);
    }
}
