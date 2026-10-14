/*
 * st7789_emu.c -- host replacement for vitis/src/hal/spi_tft.c.
 *
 * Instead of an SPI core it decodes the ST7789 command stream the TFT driver
 * sends (CASET, RASET, RAMWR + RGB565 pixels) into a frame buffer that
 * host_main.c saves as an image. Other commands are ignored.
 */
#include <stdint.h>
#include "hal/spi_tft.h"
#include "st7789_emu.h"

#define ST_CASET  0x2A
#define ST_RASET  0x2B
#define ST_RAMWR  0x2C

uint16_t emu_fb[EMU_RAM_ROWS][EMU_RAM_ROWS];

static uint8_t cmd;
static uint8_t args[4];
static int nargs;
static int xs, xe, ys, ye, cx, cy;
static uint8_t hi_byte;
static int have_hi;

static void put_pixel(uint16_t c)
{
    if (cx < EMU_RAM_ROWS && cy < EMU_RAM_ROWS) emu_fb[cy][cx] = c;
    if (++cx > xe) { cx = xs; cy++; }
}

int spi_tft_init(spi_tft_t *dev, uint32_t base, uint32_t aclk_hz, uint32_t sclk_hz)
{
    (void)dev; (void)base; (void)aclk_hz; (void)sclk_hz;
    return 0;
}

void spi_tft_hw_reset(spi_tft_t *dev) { (void)dev; }
void spi_tft_backlight(spi_tft_t *dev, int on) { (void)dev; (void)on; }
void spi_tft_flush(spi_tft_t *dev) { (void)dev; }

void spi_tft_put(spi_tft_t *dev, int dc, uint8_t byte)
{
    (void)dev;

    if (!dc) {
        cmd = byte;
        nargs = 0;
        have_hi = 0;
        if (cmd == ST_RAMWR) { cx = xs; cy = ys; }
        return;
    }

    if (cmd == ST_CASET || cmd == ST_RASET) {
        if (nargs < 4) args[nargs++] = byte;
        if (nargs == 4) {
            int a0 = (args[0] << 8) | args[1];
            int a1 = (args[2] << 8) | args[3];
            if (cmd == ST_CASET) { xs = a0; xe = a1; }
            else                 { ys = a0; ye = a1; }
        }
        return;
    }

    if (cmd == ST_RAMWR) {
        if (!have_hi) { hi_byte = byte; have_hi = 1; }
        else { put_pixel((uint16_t)((hi_byte << 8) | byte)); have_hi = 0; }
    }
}

void spi_tft_write(spi_tft_t *dev, int dc, const uint8_t *buf, uint32_t len)
{
    while (len--) spi_tft_put(dev, dc, *buf++);
}

void spi_tft_cmd(spi_tft_t *dev, uint8_t c, const uint8_t *a, uint32_t n)
{
    spi_tft_put(dev, 0, c);
    spi_tft_write(dev, 1, a, n);
}

void spi_tft_repeat16(spi_tft_t *dev, uint16_t value, uint32_t count)
{
    while (count--) {
        spi_tft_put(dev, 1, (uint8_t)(value >> 8));
        spi_tft_put(dev, 1, (uint8_t)(value & 0xFF));
    }
}
