/*============================================================================
 * tft.h -- рівень ST7789: ініціалізація, вікно, примітиви, текст.
 *
 * Колір -- RGB565: RRRRRGGG GGGBBBBB.
 *==========================================================================*/
#ifndef TFT_H
#define TFT_H

#include <stdint.h>
#include "hal/spi_tft.h"

/*------------------------------------------------- геометрія дисплея ------*/
#ifndef TFT_WIDTH
#define TFT_WIDTH   240
#endif
#ifndef TFT_HEIGHT
#define TFT_HEIGHT  320
#endif

/* ST7789 RAM is 240x320; a shorter panel sits at an offset inside it. */
#define TFT_RAM_ROWS 320
#define TFT_ROW_OFF  (TFT_RAM_ROWS - TFT_HEIGHT)

/*------------------------------------------------- готові кольори ---------*/
#define TFT_BLACK   0x0000
#define TFT_WHITE   0xFFFF
#define TFT_RED     0xF800
#define TFT_GREEN   0x07E0
#define TFT_BLUE    0x001F
#define TFT_YELLOW  0xFFE0
#define TFT_CYAN    0x07FF
#define TFT_MAGENTA 0xF81F
#define TFT_GRAY    0x8410

#define TFT_RGB(r, g, b) \
    ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))

/*------------------------------------------------- орієнтація -------------*/
typedef enum {
    TFT_ROT_0   = 0,
    TFT_ROT_90  = 1,
    TFT_ROT_180 = 2,
    TFT_ROT_270 = 3
} tft_rot_t;

typedef struct {
    spi_tft_t *spi;
    uint16_t   w;
    uint16_t   h;
    uint16_t   x_off;     /* зсув панелі, залежить від модуля */
    uint16_t   y_off;
} tft_t;

/*------------------------------------------------- API --------------------*/

/* Повна ініціалізація: скид, вихід зі сну, формат пікселя, орієнтація,
   вмикання дисплея. 0 = успіх. */
int  tft_init(tft_t *tft, spi_tft_t *spi, tft_rot_t rot);

void tft_set_rotation(tft_t *tft, tft_rot_t rot);

/* Задає прямокутник, у який далі ллються пікселі. */
void tft_set_window(tft_t *tft, uint16_t x0, uint16_t y0,
                    uint16_t x1, uint16_t y1);

void tft_clear(tft_t *tft, uint16_t color);
void tft_fill_rect(tft_t *tft, uint16_t x, uint16_t y,
                   uint16_t w, uint16_t h, uint16_t color);
void tft_draw_pixel(tft_t *tft, uint16_t x, uint16_t y, uint16_t color);
void tft_draw_hline(tft_t *tft, uint16_t x, uint16_t y, uint16_t w,
                    uint16_t color);
void tft_draw_vline(tft_t *tft, uint16_t x, uint16_t y, uint16_t h,
                    uint16_t color);
void tft_draw_rect(tft_t *tft, uint16_t x, uint16_t y,
                   uint16_t w, uint16_t h, uint16_t color);

/* Текст шрифтом 5x7 з масштабом. scale = 1 -> 5x7 пікселів. */
void tft_draw_char(tft_t *tft, uint16_t x, uint16_t y, char c,
                   uint16_t fg, uint16_t bg, uint8_t scale);
void tft_draw_text(tft_t *tft, uint16_t x, uint16_t y, const char *s,
                   uint16_t fg, uint16_t bg, uint8_t scale);

/* Потокове завантаження рядка пікселів -- для картинки з SD (Блок 2). */
void tft_blit(tft_t *tft, const uint16_t *pixels, uint32_t count);

#endif /* TFT_H */
