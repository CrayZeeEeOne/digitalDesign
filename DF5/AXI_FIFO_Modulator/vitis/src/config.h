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
#define CFG_TFT_SCLK_HZ       12500000u    /* SPI clock to the ST7789 */

/*------------------------------------------------------------- signal ----*/
#define CFG_SAMPLE_RATE_HZ    4500000u     /* complex I/Q samples per second */
#define CFG_CENTER_FREQ_HZ    868500000u   /* RF frequency of I/Q sample 0 Hz */
#define CFG_CHANNEL_FREQ_HZ   868250000u   /* channel the demodulator tunes to */
#define CFG_BITRATE           19200u       /* FSK symbols per second */

/*--------------------------------------------------------- processing ----*/
#define CFG_IQ_BLOCK          256u         /* samples per processing block */
#define CFG_WARMUP_SAMPLES    16384u       /* estimators settle, not recorded */
#define CFG_CAPTURE_SAMPLES   163840u      /* one capture: ~36 ms, ~2 packet cycles */

#endif
