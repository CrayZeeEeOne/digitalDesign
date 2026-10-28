/*
 * config.h -- system parameters of the DF5 firmware, in one place.
 *
 * Base addresses of the PL blocks live in bsp/include/xparameters.h (they
 * must match scripts/create_bd.tcl); everything else is here.
 */
#ifndef CONFIG_H
#define CONFIG_H

/*------------------------------------------------------------- clocks ----*/
#define CFG_ACLK_HZ           100000000u   /* AXI clock of MicroBlaze and the IP */
#define CFG_TFT_SCLK_HZ       25000000u    /* SPI clock to the ST7789 */

/*------------------------------------------------------------- signal ----*/
/* As in the task and sim.iq (tools/iqgen.py): LO 867.4 MHz, channel 866.31 MHz,
   i.e. the packets sit at -1.09 MHz (+3 kHz CFO) in the I/Q band. */
#define CFG_SAMPLE_RATE_HZ    4500000u     /* complex I/Q samples per second */
#define CFG_CENTER_FREQ_HZ    867400000u   /* RF frequency of I/Q sample 0 Hz */
#define CFG_CHANNEL_FREQ_HZ   866310000u   /* channel the demodulator tunes to */
#define CFG_BITRATE           19200u       /* FSK symbols per second */
#define CFG_DEVIATION_HZ      25000u       /* FSK deviation of the test generator */
#define CFG_PKT_BYTES         48u          /* bytes after the sync word, CRC included */
#define CFG_SYNC_WORD         0x91D3u

/*--------------------------------------------------------- processing ----*/
#define CFG_IQ_BLOCK          256u         /* samples per processing block (C model) */
#define CFG_WARMUP_SAMPLES    16384u       /* estimators settle, not recorded */
#define CFG_CAPTURE_SAMPLES   327680u      /* one capture: ~73 ms, two packet periods */

/* Spectrum: SPEC_FFT_N-point FFT, the SPEC_BINS central bins (+-1.125 MHz,
   ~17.6 kHz per bin); levels ~16*log2(|X|), 0 dBFS = SPEC_LOG_0DBFS. One
   waterfall row = 2^SPEC_WF_SHIFT blocks = CFG_CAPTURE_SAMPLES / 40 samples. */
#define SPEC_FFT_N            256
#define SPEC_BINS             128
/* The 128 bins shown are centred on the channel (not on the LO): the channel is
   SPEC_CH_BINS bins from the LO, the window starts SPEC_BINS/2 below it. */
#define SPEC_CH_BINS          ((int32_t)(((int64_t)CFG_CHANNEL_FREQ_HZ - (int64_t)CFG_CENTER_FREQ_HZ) * SPEC_FFT_N                                          - (int64_t)CFG_SAMPLE_RATE_HZ / 2) / (int64_t)CFG_SAMPLE_RATE_HZ)
#define SPEC_BIN0             ((uint32_t)(SPEC_CH_BINS - SPEC_BINS / 2) & (SPEC_FFT_N - 1u))
#define SPEC_LOG_0DBFS        224
#define SPEC_WF_SHIFT         5
#define CFG_LIVE_WF_SHIFT     6            /* live: one row per 64 blocks = 3.64 ms */
#define CFG_LIVE_FRAME_MS     40u          /* live: redraw at most every 40 ms */

#endif
