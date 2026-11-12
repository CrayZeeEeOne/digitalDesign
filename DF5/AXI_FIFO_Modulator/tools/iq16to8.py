#!/usr/bin/env python3
"""
iq16to8.py -- I/Q file int16 -> int8 for the real-time replay from the SD card.

The capture (int16 I, int16 Q, 4.5 MS/s) needs 18 MB/s in real time; its samples
never leave +-104, so int8 I, int8 Q holds exactly the same values at half the
rate (9 MB/s, what the 4-bit SD bus at 25 MHz delivers with room to spare). The
PL sign-extends them back (sd_host, FMT8), so the DSP sees the same numbers.

    python iq16to8.py CAPTURE.IQ CAPTURE.IQ8

Refuses to write if any sample does not fit in int8. Needs numpy.
"""
import sys

import numpy as np

CHUNK = 16 * 1024 * 1024


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src = np.memmap(sys.argv[1], dtype="<i2", mode="r")
    lo = hi = 0
    for s in range(0, len(src), CHUNK):
        a = np.asarray(src[s:s + CHUNK])
        lo, hi = min(lo, int(a.min())), max(hi, int(a.max()))
    if lo < -128 or hi > 127:
        print(f"ERROR: samples {lo}..{hi} do not fit in int8")
        return 1
    with open(sys.argv[2], "wb") as f:
        for s in range(0, len(src), CHUNK):
            np.asarray(src[s:s + CHUNK]).astype(np.int8).tofile(f)
    print(f"{sys.argv[2]}: {len(src) // 2} samples, {len(src)} bytes, values {lo}..{hi} (lossless)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
