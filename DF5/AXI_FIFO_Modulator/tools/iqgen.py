#!/usr/bin/env python3
"""
iqgen.py -- генератор тестового I/Q-запису для DF5 (Блок 3).

Створює бінарний файл у форматі з ТЗ: int16 I, int16 Q, little-endian,
чергування I0 Q0 I1 Q1 ... Усередині -- шум + кілька 2-FSK/GFSK-пакетів:

    преамбула 0xAA x N  ->  sync 0x91D3  ->  payload  ->  CRC-16/CCITT-FALSE

Поруч із .iq пишеться .json з усіма параметрами й очікуваними байтами --
його читають тестбенч RTL (через згенерований .txt) і Python-модель.

Приклади:
    python iqgen.py --out capture.iq --seconds 0.5 --bursts 3
    python iqgen.py --out sim.iq --seconds 0.08 --bursts 2 --snr 20

Параметри за замовчуванням збігаються з config.h застосунку:
    Fs = 4.5 МГц, LO = 867.4 МГц, канал = 866.31 МГц, bitrate = 19200.
"""
import argparse
import json
import struct
import sys

import numpy as np

SYNC_WORD = 0x91D3


# ----------------------------------------------------------------------------
def crc16_ccitt(data: bytes, poly=0x1021, init=0xFFFF) -> int:
    crc = init
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ poly) if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc


def bytes_to_bits(data: bytes):
    return [(b >> (7 - i)) & 1 for b in data for i in range(8)]


def gaussian_taps(bt: float, sps: float, span_bits: int = 4):
    """Імпульсна характеристика GFSK-фільтра (BT -- добуток смуги на бітовий інтервал)."""
    n = int(round(span_bits * sps))
    t = (np.arange(n) - (n - 1) / 2) / sps          # у бітових інтервалах
    alpha = np.sqrt(np.log(2) / 2) / bt
    h = (np.sqrt(np.pi) / alpha) * np.exp(-(np.pi * t / alpha) ** 2)
    return h / h.sum()


def make_burst(bits, fs, bitrate, deviation, bt, amplitude, f_offset, rng):
    """Комплексний відлік GFSK-пакета на зміщенні f_offset від нуля."""
    sps = fs / bitrate
    n_samples = int(round(len(bits) * sps))
    # NRZ +-1 з точною (нецілою) кількістю відліків на біт
    t_idx = np.arange(n_samples)
    bit_idx = np.minimum((t_idx / sps).astype(int), len(bits) - 1)
    nrz = np.array([1.0 if b else -1.0 for b in bits])[bit_idx]
    if bt > 0:
        nrz = np.convolve(nrz, gaussian_taps(bt, sps), mode="same")
    # частотна модуляція: миттєва частота = f_offset + nrz*deviation
    inst_f = f_offset + nrz * deviation
    phase = 2 * np.pi * np.cumsum(inst_f) / fs
    phase += rng.uniform(0, 2 * np.pi)
    return amplitude * np.exp(1j * phase)


# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="capture.iq")
    ap.add_argument("--fs", type=float, default=4.5e6, help="частота дискретизації, Гц")
    ap.add_argument("--lo", type=float, default=867.4e6, help="частота гетеродина, Гц")
    ap.add_argument("--channel", type=float, default=866.31e6, help="несуча пакета, Гц")
    ap.add_argument("--cfo", type=float, default=3000.0,
                    help="додаткова похибка несучої, Гц (перевірка AFC)")
    ap.add_argument("--bitrate", type=float, default=19200.0)
    ap.add_argument("--deviation", type=float, default=25e3, help="девіація FSK, Гц")
    ap.add_argument("--bt", type=float, default=0.5, help="BT гауссового фільтра, 0 = чистий FSK")
    ap.add_argument("--seconds", type=float, default=0.5)
    ap.add_argument("--bursts", type=int, default=3)
    ap.add_argument("--preamble-bytes", type=int, default=8)
    ap.add_argument("--payload-bytes", type=int, default=46,
                    help="байтів даних після sync без CRC (46 + 2 CRC = 48 = 384 біт)")
    ap.add_argument("--snr", type=float, default=18.0, help="SNR у смузі Fs, дБ")
    ap.add_argument("--amplitude", type=float, default=6000.0, help="амплітуда сигналу, LSB")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-noise", action="store_true")
    ap.add_argument("--text", default=None,
                    help="корисне навантаження як ASCII (інакше детермінований патерн)")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    n_total = int(round(args.seconds * args.fs))
    sig = np.zeros(n_total, dtype=np.complex128)

    f_offset = (args.channel - args.lo) + args.cfo

    # шум: SNR визначено відносно потужності сигналу у всій смузі Fs
    if args.no_noise:
        noise_rms = 0.0
    else:
        noise_rms = args.amplitude / np.sqrt(2) / (10 ** (args.snr / 20))
    if noise_rms > 0:
        sig += (rng.standard_normal(n_total) + 1j * rng.standard_normal(n_total)) * noise_rms

    packets = []
    # довжина пакета у відліках -- однакова для всіх, розкладаємо без перекриття
    frame_bits = (args.preamble_bytes + 2 + args.payload_bytes + 2) * 8
    burst_len = int(round(frame_bits * args.fs / args.bitrate))
    free = n_total - args.bursts * burst_len
    if free < 0:
        sys.exit(f"ERROR: {args.bursts} пакетів по {burst_len} відліків не вміщуються у "
                 f"{n_total} відліків -- збільш --seconds (потрібно >= "
                 f"{args.bursts * burst_len / args.fs:.3f} с)")
    spacing = free // (args.bursts + 1)
    for k in range(args.bursts):
        if args.text:
            body = args.text.encode("ascii", "replace")
            body = (body + b" " * args.payload_bytes)[:args.payload_bytes]
        else:
            body = bytes([(k * 17 + i * 7 + 0x42) & 0xFF for i in range(args.payload_bytes)])
            # перші байти -- читабельний маркер, щоб видно було на TFT
            tag = f"DF5 PKT{k:02d} ".encode()
            body = (tag + body[len(tag):])[:args.payload_bytes]
        crc = crc16_ccitt(body)
        frame = bytes([0xAA] * args.preamble_bytes) + struct.pack(">H", SYNC_WORD) + body + struct.pack(">H", crc)
        bits = bytes_to_bits(frame)

        burst = make_burst(bits, args.fs, args.bitrate, args.deviation, args.bt,
                           args.amplitude, f_offset, rng)
        start = spacing * (k + 1) + k * burst_len
        start = max(0, min(start, n_total - len(burst)))
        sig[start:start + len(burst)] += burst
        packets.append({
            "index": k,
            "start_sample": int(start),
            "length_samples": int(len(burst)),
            "payload_hex": body.hex(),
            "crc16": crc,
            "frame_hex": frame.hex(),
        })

    # квантування в int16, I та Q чергуються
    i16 = np.clip(np.round(sig.real), -32768, 32767).astype("<i2")
    q16 = np.clip(np.round(sig.imag), -32768, 32767).astype("<i2")
    inter = np.empty(2 * n_total, dtype="<i2")
    inter[0::2] = i16
    inter[1::2] = q16
    with open(args.out, "wb") as f:
        f.write(inter.tobytes())

    meta = {
        "file": args.out,
        "format": "int16 I, int16 Q, little-endian, interleaved",
        "fs_hz": args.fs,
        "lo_hz": args.lo,
        "channel_hz": args.channel,
        "cfo_hz": args.cfo,
        "f_offset_baseband_hz": f_offset,
        "bitrate": args.bitrate,
        "deviation_hz": args.deviation,
        "bt": args.bt,
        "snr_db": None if args.no_noise else args.snr,
        "amplitude_lsb": args.amplitude,
        "noise_rms_lsb": noise_rms,
        "samples": n_total,
        "sync_word": SYNC_WORD,
        "preamble_bytes": args.preamble_bytes,
        "payload_bytes": args.payload_bytes,
        "packet_bytes_after_sync": args.payload_bytes + 2,
        "packets": packets,
    }
    with open(args.out + ".json", "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"{args.out}: {n_total} complex samples ({4 * n_total / 1e6:.2f} MB), "
          f"{args.bursts} bursts, offset {f_offset / 1e3:+.1f} kHz, "
          f"{'no noise' if args.no_noise else f'SNR {args.snr} dB'}")
    for p in packets:
        print(f"  burst {p['index']}: start={p['start_sample']} len={p['length_samples']} "
              f"crc=0x{p['crc16']:04X} payload={p['payload_hex'][:24]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
