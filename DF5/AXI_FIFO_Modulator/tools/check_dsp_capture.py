#!/usr/bin/env python3
"""
check_dsp_capture.py -- звіряє дамп tb_dsp_top (RTL) з моделлю, біт у біт.

Вхід -- той самий I/Q-файл, що подавав тестбенч (hop.iq, вирізаний із
запису tools/make_hop_iq.py), від першого відліку після скиду:

    вхід         x 2^GAIN з насиченням до int16 (DSP_CTRL.IN_SHIFT)
    колонки raw  dsp_capture: x >> 6 з насиченням +-127, min/max на колонку
                 [c*len/384, (c+1)*len/384) від відліку T0 (затриманий потік
                 = вхідний, лише пізніше, тож T0 -- номер відліку файлу)
    waterfall    dsp_spectrum у live: блоки по 256 відліків від скиду, вікно
                 Ханна, FFT-256 q15 (кожна стадія /2, twiddle як sin_q15() у C),
                 |re|+|im| 256 бінів від BIN0, max пари сусідніх -> 128 точок,
                 рядок = spec_log(сума 2^shift блоків >> shift)
    пакети       сирі біти слайсера із захоплення: у них має знайтися кадр
                 (sync + 16 байт із PN9) з hop.iq.json без жодної помилки

    python check_dsp_capture.py <hop.iq> <dsp_capture_dump.txt>

Код повернення 0, якщо все збіглося.
"""
import argparse
import json
import math
import os
import struct
import sys

FFT_N = 256
POINTS = 128
COLS = 384
SYNC = 0x91D3


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


# twiddle-и стадій -- ті самі, що лежать у fft_tw128.mem
TW = [(sin_q15(((m * 256) + 16384) & 0xFFFF), -sin_q15(m * 256)) for m in range(128)]


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
        step = 128 // half
        for i in range(0, n, length):
            for k in range(half):
                wr, wi = TW[k * step]
                a, b = i + k, i + k + half
                tr = (re[b] * wr - im[b] * wi) >> 15
                ti = (re[b] * wi + im[b] * wr) >> 15
                re[b] = s16((re[a] - tr) >> 1)
                im[b] = s16((im[a] - ti) >> 1)
                re[a] = s16((re[a] + tr) >> 1)
                im[a] = s16((im[a] + ti) >> 1)
        length <<= 1


def spectrum_points(iq, bin0):
    """128 точок рядка з одного блоку: max |re|+|im| пари сусідніх бінів."""
    re = [s16((iq[n][0] * HANN_Q15[4 * n + 2]) >> 15) for n in range(FFT_N)]
    im = [s16((iq[n][1] * HANN_Q15[4 * n + 2]) >> 15) for n in range(FFT_N)]
    fft_q15(re, im)
    mag = []
    for n in range(FFT_N):
        k = (n + bin0) & (FFT_N - 1)
        mag.append(min(65535, abs(re[k]) + abs(im[k])))
    return [max(mag[2 * j], mag[2 * j + 1]) for j in range(POINTS)]


def spec_log(x):
    if x == 0:
        return 0
    n = x.bit_length() - 1
    frac = ((x >> (n - 4)) if n >= 4 else (x << (4 - n))) & 15
    return min(255, n * 16 + frac)


def raw_q(x):
    return max(-127, min(127, x >> 6))


def s8(x):
    return x - 256 if x & 0x80 else x


def sat16(x):
    return max(-32768, min(32767, x))


def pn9(n):
    r, out = 0x1FF, []
    for _ in range(n):
        b = 0
        for i in range(8):
            b |= (r & 1) << (7 - i)
            r = (r >> 1) | (((r ^ (r >> 5)) & 1) << 8)
        out.append(b)
    return out


def load_iq(path, gain):
    data = open(path, "rb").read()
    n = len(data) // 4
    return [(sat16(i << gain), sat16(q << gain))
            for i, q in (struct.unpack_from("<hh", data, 4 * k) for k in range(n))]


def load_dump(path):
    d = {"pkt": [], "raw": {}, "wf": {}}
    for line in open(path):
        f = line.split()
        if not f:
            continue
        if f[0] in ("T0", "LEN", "WF_SHIFT", "BIN0", "GAIN", "ROWS"):
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
        elif f[0] == "WF":
            d["wf"][int(f[1])] = int(f[2], 16)
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iq")
    ap.add_argument("dump")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    d = load_dump(args.dump)
    iq = load_iq(args.iq, d["GAIN"])
    t0, length, shift, bin0 = d["T0"], d["LEN"], d["WF_SHIFT"], d["BIN0"]
    print(f"T0={t0}, LEN={length}, GAIN=x{1 << d['GAIN']}, рядок = {1 << shift} блоків FFT, BIN0={bin0}")
    errors = 0

    # ------------------------------------------------------------ колонки --
    bad = 0
    pos = 0
    for c in range(COLS):
        end = ((c + 1) * length) // COLS
        i_lo = q_lo = 127
        i_hi = q_hi = -127
        while pos < end:
            i, q = iq[t0 + pos]
            i8, q8 = raw_q(i), raw_q(q)
            i_lo, i_hi = min(i_lo, i8), max(i_hi, i8)
            q_lo, q_hi = min(q_lo, q8), max(q_hi, q8)
            pos += 1
        w = d["raw"][c]
        got = (s8(w & 255), s8((w >> 8) & 255), s8((w >> 16) & 255), s8(w >> 24))
        if got != (i_lo, i_hi, q_lo, q_hi):
            if bad < 5:
                print(f"  колонка {c}: RTL {got}, модель {(i_lo, i_hi, q_lo, q_hi)}")
            bad += 1
    print(f"колонки raw: {COLS - bad}/{COLS} збігаються")
    errors += bad

    # ------------------------------------------------------------- спектр --
    nrows = min(d["ROWS"], 256)
    bad = 0
    peak = (0, 0, 0)
    for r in range(nrows):
        acc = [0] * POINTS
        for blk in range(r << shift, (r + 1) << shift):
            pts = spectrum_points(iq[blk * FFT_N:(blk + 1) * FFT_N], bin0)
            acc = [a + m for a, m in zip(acc, pts)]
        row = [spec_log(a >> shift) for a in acc]
        for j in range(POINTS):
            got = (d["wf"][r * 32 + j // 4] >> (8 * (j % 4))) & 255
            if got != row[j]:
                if bad < 5:
                    print(f"  waterfall рядок {r} точка {j}: RTL {got}, модель {row[j]}")
                bad += 1
            if row[j] > peak[0]:
                peak = (row[j], r, j)
    print(f"waterfall: {nrows} рядків, розбіжностей {bad}")
    lvl, r, j = peak
    print(f"найсильніша точка: рядок {r}, точка {j} "
          f"({(2 * j + bin0 - FFT_N + 0.5) * 4.5e6 / FFT_N / 1e3 + 867400:.0f} кГц), рівень {lvl}")
    errors += bad

    # ------------------------------------------------------------ пакети --
    meta = json.load(open(args.iq + ".json"))
    frames = []
    for p in meta["packets"]:
        dw = bytes.fromhex(p["bytes"])
        raw = [a ^ b for a, b in zip(dw, pn9(len(dw)))]
        frames.append([(SYNC >> (15 - i)) & 1 for i in range(16)] +
                      [(b >> (7 - i)) & 1 for b in raw for i in range(8)])
    if not d["pkt"]:
        print("у захопленні немає пакетів")
        errors += 1
    for p_idx, p in enumerate(d["pkt"]):
        nb = p["nbits"]
        bits = [(p["bytes"][k >> 3] >> (7 - (k & 7))) & 1 for k in range(nb)]
        best = None
        for f_idx, fb in enumerate(frames):
            for off in range(0, max(1, nb - len(fb) + 1)):
                e = sum(1 for k in range(len(fb)) if off + k >= nb or bits[off + k] != fb[k])
                if best is None or e < best[0]:
                    best = (e, off, f_idx)
        e, off, f_idx = best
        print(f"пакет {p_idx}: відліки {p['start']}..{p['end']}, {nb} біт; "
              f"кадр {f_idx} ({meta['packets'][f_idx]['channel_mhz']} МГц) з біта {off}, помилок {e}")
        if e:
            errors += 1

    print("РЕЗУЛЬТАТ:", "PASS" if errors == 0 else f"FAIL ({errors})")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
