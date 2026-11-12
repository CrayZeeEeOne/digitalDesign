#include "app/frame.h"
#include "config.h"

static const uint32_t hop_khz[CFG_HOP_N] = CFG_HOP_CHANNELS_KHZ;

int frame_parse(const cap_dec_t *d, frame_t *f)
{
    const uint8_t *b = d->bytes;
    uint8_t c = 0x77u;
    uint8_t i;

    f->complete = (uint8_t)(d->nbytes >= 16u && b[0] == 13u);
    f->crc8_ok = 0u;
    if (!f->complete) return 0;
    for (i = 2u; i < 13u; i++) c ^= b[i];
    f->crc8_ok = (uint8_t)(c == b[13]);
    f->num_sensor = b[2];
    f->id_central = ((uint32_t)b[3] << 16) | ((uint32_t)b[4] << 8) | b[5];
    f->pkt_num = (uint16_t)(b[6] | (b[7] << 8));
    f->cmd = b[8];
    f->alarm_cnt = b[9];
    f->zones = b[10];
    f->alarm = b[11];
    return 1;
}

uint32_t frame_ch_khz(uint8_t ch)
{
    return (ch < CFG_HOP_N) ? hop_khz[ch] : 0u;
}
