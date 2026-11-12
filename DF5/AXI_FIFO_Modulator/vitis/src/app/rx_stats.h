/* rx_stats.h -- packets received since the capture file started (shown on BITS). */
#ifndef RX_STATS_H
#define RX_STATS_H

#include <stdint.h>

typedef struct {
    uint32_t rx;               /* whole packets after sync */
    uint32_t crc16;            /* radio CRC16 OK */
    uint32_t crc8;             /* alarm frames with CRC8 OK */
    uint32_t hop_ok, hop_n;    /* next alarm on the next channel of the list / pairs checked */
} rx_stats_t;

#endif
