/* view_sd.h -- the SD CARD screen: result of the card test (app/sd_test.h). */
#ifndef VIEW_SD_H
#define VIEW_SD_H

#include "gfx/tft.h"
#include "app/sd_test.h"
#include "app/sd_format.h"

void view_sd(tft_t *tft, const sd_info_t *info, const sd_format_result_t *fmt);

/* Full-screen notice while the card is being formatted. */
void view_sd_formatting(tft_t *tft);

#endif
