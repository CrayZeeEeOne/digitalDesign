#!/usr/bin/env python3
"""
check_dsp_capture.py -- звіряє захоплення з RTL (dsp_capture + dsp_spectrum,
дамп пише tb_dsp_top) з алгоритмом C-переглядача, перенесеним сюди один в один:

    колонки raw  -- capture.c: raw_q() = x >> 6 з насиченням +-127, min/max
                    на колонку [c*len/384, (c+1)*len/384)
    спектр       -- spectrum.c + fft.c: вікно dsp_hann_q15[4n+2], FFT-256 q15
                    (кожна стадія /2), |re|+|im| 128 центральних бінів,
                    рядок = spec_log(сума / 2^shift)
    пакети       -- біти після burst: шукаємо в них кадр із sim.iq.json

    python check_dsp_capture.py <sim.iq> <dsp_capture_dump.txt> [--warmup 16384]

Код повернення 0, якщо колонки й waterfall збігаються біт у біт,
а в кожному пакеті кадр знайдено без помилок.
"""
import argparse
import json
import math
import os
import struct
import sys

FFT_N = 256
BINS = 128
COLS = 384
WF_ROWS = 40


def q15(x):
    return max(-32768, min(32767, int(round(x * 32767))))


SIN_Q15 = [q15(math.sin(2 * math.pi * k / 1024)) for k in range(257)]
HANN_Q15 = [q15(0.5 * (1 - math.cos(2 * math.pi * n / 1024))) for n in range(1024)]


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def sin_q15(phase):
    idx = (phase >> 6) & 1023
    q, o = idx >> 8, idx & 255
    if q == 0:
        return SIN_Q15[o]
    if q == 1:
        return SIN_Q15[256 - o]
    if q == 2:
        return -SIN_Q15[o]
    return -SIN_Q15[256 - o]


def fft_q15(re, im):
    n = len(re)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            re[i], re[j] = re[j], re[i]
            im[i], im[j] = im[j], im[i]
    length = 2
    while length <= n:
        half = length >> 1
        dph = 65536 // length
        for i in range(0, n, length):
            for k in range(half):
                ph = (k * dph) & 0xFFFF
                wr = sin_q15((ph + 16384) & 0xFFFF)
                wi = -sin_q15(ph)
                a, b = i + k, i + k + half
                tr = (re[b] * wr - im[b] * wi) >> 15
                ti = (re[b] * wi + im[b] * wr) >> 15
                re[b] = s16((re[a] - tr) >> 1)
                im[b] = s16((im[a] - ti) >> 1)
                re[a] = s16((re[a] + tr) >> 1)
                im[a] = s16((im[a] + ti) >> 1)
        length <<= 1


def spectrum_mag(iq, bin0=192):
    re = [s16((iq[n][0] * HANN_Q15[4 * n + 2]) >> 15) for n in range(FFT_N)]
    im = [s16((iq[n][1] * HANN_Q15[4 * n + 2]) >> 15) for n in range(FFT_N)]
    fft_q15(re, im)
    mag = []
    for n in range(BINS):
        k = (n + bin0) & (FFT_N - 1)
        mag.append(min(65535, abs(re[k]) + abs(im[k])))
    return mag


def spec_log(x):
    if x == 0:
        return 0
    n = x.bit_length() - 1
    frac = ((x >> (n - 4)) if n >= 4 else (x << (4 - n))) & 15
    return min(255, n * 16 + frac)


def raw_q(x):
    v = x >> 6
    return max(-127, min(127, v))


def s8(x):
    return x - 256 if x & 0x80 else x


def load_iq(path):
    data = open(path, "rb").read()
    n = len(data) // 4
    return [struct.unpack_from("<hh", data, 4 * k) for k in range(n)]


def load_dump(path):
    d = {"pkt": [], "raw": {}, "mh": {}, "wf": {}}
    for line in open(path):
        f = line.split()
        if not f:
            continue
        if f[0] in ("T0", "LEN", "WF_SHIFT", "BIN0"):
            d[f[0]] = int(f[1])
        elif f[0] == "STATUS":
            d["STATUS"] = int(f[1], 16)
        elif f[0] == "PKT":
            words = [int(w.replace("x", "0"), 16) for w in f[6:]]   # x = байт не записано
            data = b"".join(struct.pack("<I", w) for w in words)
            d["pkt"].append({"start": int(f[2]), "end": int(f[3]), "first": int(f[4]),
                             "nbits": int(f[5]), "bytes": data})
        elif f[0] == "RAW":
            d["raw"][int(f[1])] = int(f[2], 16)
        elif f[0] == "MH":
            d["mh"][int(f[1])] = int(f[2], 16)
        elif f[0] == "WF":
            d["wf"][int(f[1])] = int(f[2], 16)
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iq")
    ap.add_argument("dump")
    ap.add_argument("--warmup", type=int, default=16384,
                    help="відліків файлу до початку запису (режим без очікування пакета)")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    iq = load_iq(args.iq)
    d = load_dump(args.dump)
    t0, length, shift = d["T0"], d["LEN"], d["WF_SHIFT"]
    g0 = t0 - args.warmup                 # глобальний номер відліку 0 файлу
    print(f"T0={t0} (відлік файлу {args.warmup}), LEN={length}, рядок = {1 << shift} блоків FFT")
    errors = 0

    # ------------------------------------------------------------ колонки --
    cols = []
    pos = 0
    for c in range(COLS):
        end = ((c + 1) * length) // COLS
        i_lo = q_lo = 127
        i_hi = q_hi = -127
        while pos < end:
            i, q = iq[args.warmup + pos]
            i8, q8 = raw_q(i), raw_q(q)
            i_lo, i_hi = min(i_lo, i8), max(i_hi, i8)
            q_lo, q_hi = min(q_lo, q8), max(q_hi, q8)
            pos += 1
        cols.append((i_lo, i_hi, q_lo, q_hi))
    bad = 0
    for c in range(COLS):
        w = d["raw"][c]
        got = (s8(w & 255), s8((w >> 8) & 255), s8((w >> 16) & 255), s8(w >> 24))
        if got != cols[c]:
            if bad < 5:
                print(f"  колонка {c}: RTL {got}, модель {cols[c]}")
            bad += 1
    print(f"колонки raw: {COLS - bad}/{COLS} збігаються")
    errors += bad

    # ------------------------------------------------------------- спектр --
    first_blk = t0 // FFT_N
    last_blk = (t0 + length - 1) // FFT_N
    acc = [0] * BINS
    blocks = 0
    rows = []
    for blk in range(first_blk, last_blk + 1):
        k0 = blk * FFT_N - g0
        mag = spectrum_mag(iq[k0:k0 + FFT_N], d.get("BIN0", 192))
        acc = [a + m for a, m in zip(acc, mag)]
        blocks += 1
        if blocks == (1 << shift):
            if len(rows) < WF_ROWS:
                rows.append([spec_log(a >> shift) for a in acc])
            acc = [0] * BINS
            blocks = 0
    mh = [max([r[b] for r in rows] + [0]) for b in range(BINS)]

    bad = 0
    for r in range(WF_ROWS):
        for w in range(BINS // 4):
            word = d["wf"][r * 32 + w]
            for lane in range(4):
                b = 4 * w + lane
                got = (word >> (8 * lane)) & 255
                exp = rows[r][b] if r < len(rows) else 0
                if got != exp:
                    if bad < 5:
                        print(f"  waterfall рядок {r} бін {b}: RTL {got}, модель {exp}")
                    bad += 1
    print(f"waterfall: {len(rows)} рядків, розбіжностей {bad}")
    errors += bad
    peak = max(range(BINS), key=lambda b: mh[b])
    print(f"max hold (з рядків): пік у біні {peak} "
          f"({((peak + d.get('BIN0', 192)) % FFT_N - (FFT_N if (peak + d.get('BIN0', 192)) % FFT_N >= FFT_N // 2 else 0)) * 4.5e6 / FFT_N / 1e3:+.0f} кГц від LO), рівень {mh[peak]}")

    # ------------------------------------------------------------ пакети --
    meta_path = args.iq + ".json"
    frames = []
    if os.path.exists(meta_path):
        meta = json.load(open(meta_path))
        frames = [bytes.fromhex(p["frame_hex"]) for p in meta["packets"]]
    for p_idx, p in enumerate(d["pkt"]):
        nb = p["nbits"]
        bits = [(p["bytes"][k >> 3] >> (7 - (k & 7))) & 1 for k in range(nb)]
        print(f"пакет {p_idx}: відліки {p['start']}..{p['end']}, перший біт @{p['first']}, {nb} біт")
        best = None
        for fr in frames:
            fb = [(b >> (7 - i)) & 1 for b in fr for i in range(8)]
            # кадр без перших біт преамбули (поки детектор і AFC входять у пакет)
            tail = fb[16:]
            for off in range(0, max(1, nb - len(tail) + 1)):
                e = sum(1 for k in range(len(tail)) if off + k >= nb or bits[off + k] != tail[k])
                if best is None or e < best[0]:
                    best = (e, off, fr)
        if best is None:
            continue
        e, off, fr = best
        print(f"   кадр {fr[10:20]!r}...: біти з {off} (кадр від біта 16), помилок {e}")
        if e:
            errors += 1

    print("РЕЗУЛЬТАТ:", "PASS" if errors == 0 else f"FAIL ({errors})")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
