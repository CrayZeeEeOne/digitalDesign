/*============================================================================
 * spi_tft.h -- низький рівень: регістри spi_tft_ctrl, передача байтів.
 *
 * Нічого не знає про ST7789 -- лише штовхає байти і керує DC/CS/RESET.
 *==========================================================================*/
#ifndef SPI_TFT_H
#define SPI_TFT_H

#include <stdint.h>

/*--------------------------------------------------------- мапа регістрів */
#define SPI_TFT_REG_CTRL      0x00
#define SPI_TFT_REG_CLKDIV    0x04
#define SPI_TFT_REG_TXDATA    0x08
#define SPI_TFT_REG_STATUS    0x0C
#define SPI_TFT_REG_ID        0x10

/*------------------------------------------------------------- біти CTRL */
#define SPI_TFT_CTRL_ENABLE   (1u << 0)
#define SPI_TFT_CTRL_DC       (1u << 1)   /* 0 = команда, 1 = дані         */
#define SPI_TFT_CTRL_RST_N    (1u << 2)   /* 0 = дисплей у скиді           */
#define SPI_TFT_CTRL_CS_N     (1u << 3)   /* ручний CS, активний 0         */
#define SPI_TFT_CTRL_CS_AUTO  (1u << 4)
#define SPI_TFT_CTRL_BLK      (1u << 5)   /* підсвітка, 1 = увімкнена      */

/*----------------------------------------------------------- біти STATUS */
#define SPI_TFT_ST_BUSY       (1u << 0)
#define SPI_TFT_ST_TX_FULL    (1u << 1)
#define SPI_TFT_ST_TX_EMPTY   (1u << 2)
#define SPI_TFT_ST_LEVEL_SH   4
#define SPI_TFT_ST_LEVEL_MSK  0x1F        /* [8:4]: 0..SPI_TFT_FIFO_DEPTH */
#define SPI_TFT_FIFO_DEPTH    16u

#define SPI_TFT_ID_EXPECTED   0x5F778901u

/*---------------------------------------------------------------- типи   */
typedef struct {
    uint32_t base;        /* базова адреса з xparameters.h */
    uint32_t aclk_hz;     /* частота AXI-такту             */
} spi_tft_t;

/*---------------------------------------------------------------- API    */

/* Перевіряє ID, вмикає ядро, ставить частоту SCLK. 0 = успіх, <0 = помилка. */
int  spi_tft_init(spi_tft_t *dev, uint32_t base, uint32_t aclk_hz,
                  uint32_t sclk_hz);

/* Апаратний скид дисплея: RESET вниз, пауза, вгору, пауза. */
void spi_tft_hw_reset(spi_tft_t *dev);

/* Підсвітка. Після скиду вимкнена -- вмикати після tft_init(). */
void spi_tft_backlight(spi_tft_t *dev, int on);

/* Блокуюче очікування, поки FIFO спорожніє і передача завершиться. */
void spi_tft_flush(spi_tft_t *dev);

/* Один байт. dc = 0 -> команда, dc = 1 -> дані. Блокує, якщо FIFO повний. */
void spi_tft_put(spi_tft_t *dev, int dc, uint8_t byte);

/* Масив байтів з одним і тим самим DC. */
void spi_tft_write(spi_tft_t *dev, int dc, const uint8_t *buf, uint32_t len);

/* Команда + необов'язкові параметри одним викликом. */
void spi_tft_cmd(spi_tft_t *dev, uint8_t cmd, const uint8_t *args, uint32_t n);

/* Повторити 16-бітне слово count разів (заливка областей кольором). */
void spi_tft_repeat16(spi_tft_t *dev, uint16_t value, uint32_t count);

/* n 16-bit pixels (RGB565, MSB first) as data; fills the FIFO in bursts:
   the status is read once per burst, not once per byte. */
void spi_tft_write16(spi_tft_t *dev, const uint16_t *px, uint32_t n);

#endif /* SPI_TFT_H */
