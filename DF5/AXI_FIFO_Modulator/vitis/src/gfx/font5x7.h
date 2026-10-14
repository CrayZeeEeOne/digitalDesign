/*============================================================================
 * font5x7.h -- растровий шрифт 5x7.
 *==========================================================================*/
#ifndef FONT5X7_H
#define FONT5X7_H

#include <stdint.h>

#define FONT_W         5      /* стовпців у глифі                          */
#define FONT_H         7      /* рядків у глифі                            */
#define FONT_ADVANCE   6      /* крок між символами (глиф + 1 пробіл)      */
#define FONT_FIRST     0x20   /* перший закодований символ                 */
#define FONT_LAST      0x5F
#define FONT_N_CHARS   (FONT_LAST - FONT_FIRST + 1)

extern const uint8_t font5x7[FONT_N_CHARS][FONT_W];

#endif /* FONT5X7_H */
