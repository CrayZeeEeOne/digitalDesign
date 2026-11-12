#!/usr/bin/env python3
"""
make_hop_iq.py -- short test file for the RTL from the real capture.

The capture (capture_300MB.iq: 75 M samples, int16 I/Q, Fs 4.5 MHz, LO 867.4 MHz)
holds Alarm-Beacon GFSK packets hopping over 15 channels. This script

  1. finds the strong bursts per channel (FFT-256, power of the 3 bins around
     each channel, threshold 4 x median);
  2. demodulates each with a plain float demodulator (mix, average /16, angle
     difference, slicer, best sampling phase) and checks the frame:
     sync 0x91D3, 16 bytes whitened with PN9 (seed 0x1FF), radio CRC16
     (poly 0x1021, start 0x1D0F, inverted) -- the reference for the RTL;
  3. with --out: cuts the first --count packets with noise around them and
     writes them back to back (hop.iq) plus the expected result (hop.iq.json).

    python make_hop_iq.py capture_300MB.iq                 # list every packet
    python make_hop_iq.py capture_300MB.iq --out ../vivado/sources/sim_data/hop.iq

Needs numpy.
"""
import argparse
import json
import sys

import numpy as np

FS = 4.5e6
LO = 867.4e6
N = 256
BITRATE = 19200
CHANNELS_MHZ = [865.3, 865.5, 865.9, 866.1, 866.5, 866.7, 867.1, 867.3,
                867.7, 867.9, 868.1, 868.3, 868.9, 869.1, 869.5]
SYNC = 0x91D3
FRAME_BYTES = 16
LEAD = 40000            # noise before a packet in the test file (demodulator warm-up)
TAIL = 66000            # samples after the burst start (the packet is ~54300)


def pn9(n):
    r, out = 0x1FF, []
    for _ in range(n):
        b = 0
        for i in range(8):
            b |= (r & 1) << (7 - i)
            r = (r >> 1) | (((r ^ (r >> 5)) & 1) << 8)
        out.append(b)
    return out


def crc16(data, c=0x1D0F):
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def find_bursts(x):
    """(start block, end block, channel) of the strong bursts, in time order."""
    cb = [int(round((c * 1e6 - LO) / FS * N)) for c in CHANNELS_MHZ]
    nb = len(x) // 2 // N
    p = np.zeros((nb, len(cb)), np.float32)
    win = np.hanning(N)
    for s in range(0, nb, 20000):
        e = min(nb, s + 20000)
        a = x[2 * s * N:2 * e * N].astype(np.float32)
        spec = np.abs(np.fft.fft((a[0::2] + 1j * a[1::2]).reshape(-1, N) * win, axis=1))
        for k, b in enumerate(cb):
            p[s:e, k] = spec[:, [(b - 1) % N, b % N, (b + 1) % N]].sum(1)
    on = p > np.median(p, axis=0) * 4
    ev = []
    for k in range(len(cb)):
        d = np.diff(np.r_[0, on[:, k].astype(int), 0])
        for a, b in zip(np.where(d == 1)[0], np.where(d == -1)[0]):
            if b - a >= 40:                       # >= 2.3 ms: the 12 ms alarm packets
                ev.append((int(a), int(b), k))
    return sorted(ev)


def demod(x, start, k):
    """Dewhitened frame bytes of the burst starting at sample `start` on channel k, or None."""
    s0 = max(0, start - 4000)
    seg = x[2 * s0:2 * (start + 60000)].astype(np.float64)
    z = seg[0::2] + 1j * seg[1::2]
    z = z * np.exp(-2j * np.pi * (CHANNELS_MHZ[k] * 1e6 - LO) * np.arange(len(z)) / FS)
    z = np.convolve(z, np.ones(16) / 16, "same")[::16]
    d = np.angle(z[1:] * np.conj(z[:-1]))
    pw = np.abs(z[1:]) ** 2
    idx = np.where(pw > pw.max() / 10)[0]
    d = d[idx[0]:idx[-1]]
    d = d - d.mean()
    sps = FS / 16 / BITRATE
    sync = format(SYNC, "016b")
    for ph in np.arange(0, sps, 0.5):
        bits = "".join("1" if v > 0 else "0" for v in d[np.arange(ph, len(d) - 1, sps).astype(int)])
        p = bits.find(sync)
        if p < 0 or len(bits) < p + 16 + 8 * FRAME_BYTES:
            continue
        raw = [int(bits[p + 16 + 8 * i:p + 24 + 8 * i], 2) for i in range(FRAME_BYTES)]
        dw = [a ^ b for a, b in zip(raw, pn9(FRAME_BYTES))]
        if crc16(dw[:14]) ^ 0xFFFF == (dw[14] << 8 | dw[15]):
            return dw
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--out", help="write the test file (and <out>.json)")
    ap.add_argument("--count", type=int, default=3, help="packets in the test file")
    a = ap.parse_args()

    x = np.memmap(a.capture, dtype="<i2", mode="r")
    pkts = []
    for b0, b1, k in find_bursts(x):
        dw = demod(x, b0 * N, k)
        pkts.append((b0 * N, k, dw))
        print("%9d  %.1f MHz  %s" % (b0 * N, CHANNELS_MHZ[k],
                                     " ".join("%02X" % v for v in dw) if dw else "no frame"))
    ok = [p for p in pkts if p[2]]
    print("%d bursts, %d frames with CRC16 OK" % (len(pkts), len(ok)))
    if not a.out:
        return 0

    out, meta = [], []
    pos = 0
    for start, k, dw in ok[:a.count]:
        seg = np.array(x[2 * (start - LEAD):2 * (start + TAIL)], dtype="<i2")
        out.append(seg)
        meta.append({"burst_start": pos + LEAD, "channel_mhz": CHANNELS_MHZ[k], "channel": k,
                     "bytes": "".join("%02x" % v for v in dw), "capture_sample": start})
        pos += len(seg) // 2
    np.concatenate(out).tofile(a.out)
    with open(a.out + ".json", "w") as f:
        json.dump({"source": a.capture.replace("\\", "/").split("/")[-1], "fs": FS, "lo": LO,
                   "samples": pos, "packets": meta}, f, indent=1)
    print("%s: %d samples, %d packets" % (a.out, pos, len(meta)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
