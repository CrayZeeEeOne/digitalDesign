/* dsp_tables.h -- ЗГЕНЕРОВАНО tools/gen_mem.py, не редагувати вручну. */
#ifndef DSP_TABLES_H
#define DSP_TABLES_H

#include <stdint.h>

#define DSP_FFT_N 1024

extern const int16_t dsp_sin_q15[DSP_FFT_N / 4 + 1];
extern const int16_t dsp_hann_q15[DSP_FFT_N];

#endif /* DSP_TABLES_H */
