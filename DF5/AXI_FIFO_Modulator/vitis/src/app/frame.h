/*
 * frame.h -- the Alarm-Beacon frame of the capture, after sync and PN9
 * (DoorProtect firmware, ABF_Process; decoder.py of the reference analysis):
 *
 *   [0]      length = 13 (bytes that follow, without the CRC16)
 *   [1]      network byte
 *   [2]      num_sensor
 *   [3..5]   id_central, most significant byte first
 *   [6..7]   packet number, least significant byte first
 *   [8]      command (0x1F = alarm)
 *   [9]      alarm counter
 *   [10]     zones
 *   [11]     alarm field (0x04 = reed switch open)
 *   [12]     alarm field Ex
 *   [13]     CRC8 over [2..12]: 0x77 XOR the bytes
 *   [14..15] radio CRC16 (checked by the demodulator)
 */
#ifndef FRAME_H
#define FRAME_H

#include <stdint.h>
#include "app/capture.h"

#define FRAME_CMD_ALARM 0x1Fu

typedef struct {
    uint8_t complete;          /* 16 bytes, length 13 */
    uint8_t crc8_ok;
    uint8_t num_sensor;
    uint32_t id_central;
    uint16_t pkt_num;
    uint8_t cmd;
    uint8_t alarm_cnt;
    uint8_t zones;
    uint8_t alarm;
} frame_t;

/* Fields of a decoded packet. Returns f->complete. */
int frame_parse(const cap_dec_t *d, frame_t *f);

/* Channel frequency in kHz of hop channel ch. */
uint32_t frame_ch_khz(uint8_t ch);

#endif
