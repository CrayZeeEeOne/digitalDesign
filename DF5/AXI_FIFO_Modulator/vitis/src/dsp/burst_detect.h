/*
 * burst_detect.h -- power estimator and packet (burst) detector.
 *
 *   pavg   = smoothed |i| + |q|                (1/16 per sample)
 *   noise  = smoothed pavg, frozen during a burst (1/32 per sample)
 *   burst  = pavg > threshold(noise); ends after BURST_HANG samples below it
 *
 * RTL counterpart: demod_power.sv.
 */
#ifndef BURST_DETECT_H
#define BURST_DETECT_H

#include <stdint.h>

#define BURST_HANG 16

typedef struct {
    uint32_t pavg;
    uint32_t noise;
    uint8_t burst;
    uint8_t hang;
} burst_detect_t;

void burst_detect_init(burst_detect_t *b);

/* Detection threshold for a given noise level: 1.5 * noise, kept in 700..4095. */
uint32_t burst_threshold(uint32_t noise);

/* Returns 1 on the sample where a burst starts. */
int burst_detect_step(burst_detect_t *b, int16_t i, int16_t q);

#endif
