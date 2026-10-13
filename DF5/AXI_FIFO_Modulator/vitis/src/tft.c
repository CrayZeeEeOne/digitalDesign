/*============================================================================
 * tft.c -- ST7789 driver level.
 *==========================================================================*/
#include "tft.h"
#include "font5x7.h"

#define ST_SWRESET  0x01
#define ST_SLPOUT   0x11
#define ST_NORON    0x13
#define ST_INVON    0x21
#define ST_DISPON   0x29
#define ST_CASET    0x2A
#define ST_RASET    0x2B
#define ST_RAMWR    0x2C
#define ST_MADCTL   0x36
#define ST_COLMOD   0x3A

#define MADCTL_MY   0x80
#define MADCTL_MX   0x40
#define MADCTL_MV   0x20
#define MADCTL_BGR  0x08

static void delay_ms(uint32_t ms)
{
    volatile uint32_t i;
    while (ms--)
        for (i = 0; i < 20000; i++)
            ;
}

int tft_init(tft_t *tft, spi_tft_t *spi, tft_rot_t rot)
{
    uint8_t arg;

    tft->spi   = spi;
    tft->x_off = 0;
    tft->y_off = TFT_ROW_OFF;

    spi_tft_hw_reset(spi);

    spi_tft_cmd(spi, ST_SWRESET, 0, 0);
    spi_tft_flush(spi);
    delay_ms(150);

    spi_tft_cmd(spi, ST_SLPOUT, 0, 0);
    spi_tft_flush(spi);
    delay_ms(120);

    arg = 0x55;
    spi_tft_cmd(spi, ST_COLMOD, &arg, 1);

    tft_set_rotation(tft, rot);

    spi_tft_cmd(spi, ST_INVON, 0, 0);
    spi_tft_cmd(spi, ST_NORON, 0, 0);
    spi_tft_flush(spi);
    delay_ms(10);

    spi_tft_cmd(spi, ST_DISPON, 0, 0);
    spi_tft_flush(spi);
    delay_ms(10);

    return 0;
}

void tft_set_rotation(tft_t *tft, tft_rot_t rot)
{
    uint8_t m;

    switch (rot) {
    case TFT_ROT_90:
        m          = MADCTL_MV | MADCTL_MX | MADCTL_BGR;
        tft->w     = TFT_HEIGHT;
        tft->h     = TFT_WIDTH;
        tft->x_off = TFT_ROW_OFF;
        tft->y_off = 0;
        break;
    case TFT_ROT_180:
        m          = MADCTL_MX | MADCTL_MY | MADCTL_BGR;
        tft->w     = TFT_WIDTH;
        tft->h     = TFT_HEIGHT;
        tft->x_off = 0;
        tft->y_off = 0;
        break;
    case TFT_ROT_270:
        m          = MADCTL_MV | MADCTL_MY | MADCTL_BGR;
        tft->w     = TFT_HEIGHT;
        tft->h     = TFT_WIDTH;
        tft->x_off = 0;
        tft->y_off = TFT_ROW_OFF;
        break;
    default:
        m          = MADCTL_BGR;
        tft->w     = TFT_WIDTH;
        tft->h     = TFT_HEIGHT;
        tft->x_off = 0;
        tft->y_off = TFT_ROW_OFF;
        break;
    }

    spi_tft_cmd(tft->spi, ST_MADCTL, &m, 1);
}

void tft_set_window(tft_t *tft, uint16_t x0, uint16_t y0,
                    uint16_t x1, uint16_t y1)
{
    uint8_t a[4];

    x0 += tft->x_off;  x1 += tft->x_off;
    y0 += tft->y_off;  y1 += tft->y_off;

    a[0] = (uint8_t)(x0 >> 8);  a[1] = (uint8_t)(x0 & 0xFF);
    a[2] = (uint8_t)(x1 >> 8);  a[3] = (uint8_t)(x1 & 0xFF);
    spi_tft_cmd(tft->spi, ST_CASET, a, 4);

    a[0] = (uint8_t)(y0 >> 8);  a[1] = (uint8_t)(y0 & 0xFF);
    a[2] = (uint8_t)(y1 >> 8);  a[3] = (uint8_t)(y1 & 0xFF);
    spi_tft_cmd(tft->spi, ST_RASET, a, 4);

    spi_tft_cmd(tft->spi, ST_RAMWR, 0, 0);
}

void tft_fill_rect(tft_t *tft, uint16_t x, uint16_t y,
                   uint16_t w, uint16_t h, uint16_t color)
{
    if (x >= tft->w || y >= tft->h || w == 0 || h == 0)
        return;
    if (x + w > tft->w) w = tft->w - x;
    if (y + h > tft->h) h = tft->h - y;

    tft_set_window(tft, x, y, x + w - 1, y + h - 1);
    spi_tft_repeat16(tft->spi, color, (uint32_t)w * h);
}

void tft_clear(tft_t *tft, uint16_t color)
{
    tft_fill_rect(tft, 0, 0, tft->w, tft->h, color);
}

void tft_draw_pixel(tft_t *tft, uint16_t x, uint16_t y, uint16_t color)
{
    tft_fill_rect(tft, x, y, 1, 1, color);
}

void tft_draw_hline(tft_t *tft, uint16_t x, uint16_t y, uint16_t w,
                    uint16_t color)
{
    tft_fill_rect(tft, x, y, w, 1, color);
}

void tft_draw_vline(tft_t *tft, uint16_t x, uint16_t y, uint16_t h,
                    uint16_t color)
{
    tft_fill_rect(tft, x, y, 1, h, color);
}

void tft_draw_rect(tft_t *tft, uint16_t x, uint16_t y,
                   uint16_t w, uint16_t h, uint16_t color)
{
    if (w == 0 || h == 0)
        return;
    tft_draw_hline(tft, x, y, w, color);
    tft_draw_hline(tft, x, y + h - 1, w, color);
    tft_draw_vline(tft, x, y, h, color);
    tft_draw_vline(tft, x + w - 1, y, h, color);
}

void tft_draw_char(tft_t *tft, uint16_t x, uint16_t y, char c,
                   uint16_t fg, uint16_t bg, uint8_t scale)
{
    const uint8_t *g;
    uint16_t cw, ch;
    int col, row, sx, sy;
    uint16_t px;

    if (scale == 0)
        scale = 1;
    if ((unsigned char)c < FONT_FIRST || (unsigned char)c > FONT_LAST)
        c = '?';

    g = font5x7[(unsigned char)c - FONT_FIRST];
    cw = (uint16_t)FONT_ADVANCE * scale;
    ch = (uint16_t)FONT_H * scale;

    if (x >= tft->w || y >= tft->h)
        return;

    tft_set_window(tft, x, y, x + cw - 1, y + ch - 1);

    for (row = 0; row < FONT_H; row++) {
        for (sy = 0; sy < scale; sy++) {
            for (col = 0; col < FONT_ADVANCE; col++) {
                px = (col < FONT_W && (g[col] & (1u << row))) ? fg : bg;
                for (sx = 0; sx < scale; sx++)
                    spi_tft_repeat16(tft->spi, px, 1);
            }
        }
    }
}

void tft_draw_text(tft_t *tft, uint16_t x, uint16_t y, const char *s,
                   uint16_t fg, uint16_t bg, uint8_t scale)
{
    uint16_t cx = x;
    uint16_t step;

    if (scale == 0)
        scale = 1;
    step = (uint16_t)FONT_ADVANCE * scale;

    while (*s) {
        if (*s == '\n') {
            cx = x;
            y += (uint16_t)FONT_H * scale + scale;
            s++;
            continue;
        }
        if (cx + step > tft->w)
            break;
        tft_draw_char(tft, cx, y, *s, fg, bg, scale);
        cx += step;
        s++;
    }
}

void tft_blit(tft_t *tft, const uint16_t *pixels, uint32_t count)
{
    uint32_t i;
    uint8_t b[2];

    for (i = 0; i < count; i++) {
        b[0] = (uint8_t)(pixels[i] >> 8);
        b[1] = (uint8_t)(pixels[i] & 0xFF);
        spi_tft_write(tft->spi, 1, b, 2);
    }
}
