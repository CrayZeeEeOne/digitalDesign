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
/* The real capture (capture_300MB.iq, copied to the card as CFG_PLAY_FILE):
   Pluto SDR, LO 867.4 MHz, 4.5 MS/s, int16 I/Q, 16.7 s. Alarm-Beacon GFSK
   packets hop over the 15 channels below, one packet every ~283 ms; frame:
   10 x 0xAA, sync 0x91D3, 16 bytes whitened with PN9, radio CRC16. */
#define CFG_SAMPLE_RATE_HZ    4500000u     /* complex I/Q samples per second */
#define CFG_CENTER_FREQ_HZ    867400000u   /* RF frequency of I/Q sample 0 Hz (LO) */
#define CFG_BITRATE           19200u       /* GFSK symbols per second */
#define CFG_PKT_BYTES         16u          /* bytes after the sync word, CRC16 included */
#define CFG_SYNC_WORD         0x91D3u
#define CFG_IN_SHIFT          6u           /* input x 64: the capture peaks at ~+-104 LSB */
#define CFG_PLAY_FILE         "CAPTURE.IQ8"  /* int8 I/Q (tools/iq16to8.py): real time */
#define CFG_PLAY_FILE16       "CAPTURE.IQ"   /* int16, if there is no .IQ8: ~0.7x real time */
#define CFG_PLAY_RATE         193273528u     /* 2^32 * 4.5 MS/s / 100 MHz: the replay rate */

/* Hop channels, kHz, in the order the transmitter uses them. */
#define CFG_HOP_N             15u
#define CFG_HOP_CHANNELS_KHZ  { 865300u, 865500u, 865900u, 866100u, 866500u, 866700u, 867100u, \
                                867300u, 867700u, 867900u, 868100u, 868300u, 868900u, 869100u, \
                                869500u }

/* Channel search in the PL (dsp_hop): a packet is a channel whose level sum over
   3 FFT bins is above max(noise << THR_SH, MIN) for CONFIRM blocks in a row.
   Alarm packets give sums of ~5000..8000, the noise of the capture ~1..10. */
#define CFG_HOP_THR_SH        5u           /* x32, ~30 dB above the channel noise */
#define CFG_HOP_MIN           256u
#define CFG_HOP_NOISE_SH      4u
#define CFG_HOP_CONFIRM       2u
#define CFG_HOP_HOLD          8192u        /* samples to wait for the packet after retuning */

/*--------------------------------------------------------- processing ----*/
#define CFG_IQ_BLOCK          256u         /* samples per processing block (C model) */
#define CFG_WARMUP_SAMPLES    1u           /* the demodulator runs continuously */
#define CFG_CAPTURE_SAMPLES   98304u       /* one capture: 21.8 ms from just before a packet */

/* Spectrum: SPEC_FFT_N-point FFT over the whole band (+-2.25 MHz around the LO);
   each of the SPEC_BINS points is the max of 2 neighbouring FFT bins (35.2 kHz).
   Levels ~16*log2(|X|), 0 dBFS = SPEC_LOG_0DBFS. */
#define SPEC_FFT_N            256
#define SPEC_BINS             128
#define SPEC_BIN0             128u         /* first FFT bin shown: -Fs/2 */
#define SPEC_LOG_0DBFS        224
#define SPEC_WF_SHIFT         6            /* capture mode (host model): one row = 64 blocks = 3.64 ms */
#define CFG_LIVE_WF_SHIFT     11           /* play: one row = 2048 blocks = 116.5 ms, the whole
                                              16.7 s file = 144 rows of the 256-row ring */
#define CFG_LIVE_FRAME_MS     50u          /* redraw at most every 50 ms */

#endif
