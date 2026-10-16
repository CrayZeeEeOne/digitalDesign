#include "app/zoom.h"

static void clamp_off(zoom_t *z, int32_t off, uint16_t n)
{
    int32_t max = (int32_t)n - (int32_t)zoom_span(z, n);

    if (off > max) off = max;
    if (off < 0) off = 0;
    z->off = (uint16_t)off;
}

void zoom_cycle(zoom_t *z, uint16_t n)
{
    int32_t center = (int32_t)z->off + zoom_span(z, n) / 2;

    z->level = (uint8_t)((z->level + 1u) % ZOOM_LEVELS);
    clamp_off(z, center - zoom_span(z, n) / 2, n);
}

int zoom_pan(zoom_t *z, uint16_t n, int dir)
{
    uint16_t old = z->off;
    int32_t step = zoom_span(z, n) / 8;

    if (step < 1) step = 1;
    clamp_off(z, (int32_t)z->off + (dir < 0 ? -step : step), n);
    return z->off != old;
}
