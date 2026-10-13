#!/usr/bin/env python3
"""
demod_model.py -- еталонна цілочисельна модель rtl_demod.sv.

Повторює арифметику RTL крок за кроком (NCO -> мікшер -> CIC3 -> дискримінатор
на CORDIC -> слайсер з AFC -> відновлення тактів -> sync -> пакет -> CRC), щоб:

  * перевірити алгоритм на згенерованому .iq ще до написання RTL;
  * мати очікувані результати для тестбенча;
  * пояснити, що саме рахує залізо і як софт переводить це в герци.

Запуск:
    python demod_model.py ../vivado/sources/sim_data/sim.iq
    python demod_model.py capture.iq --nco-hz 1090000 --dump trace.txt
"""
import argparse
import json
import math
import os
import struct
import sys

# Windows-консоль за замовчуванням cp1252 -- кирилиця у виводі падає без цього
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# ---------------------------------------------------------------- константи ---
NCO_LUT_N   = 1024
CORDIC_IT   = 16
ANGLE_PI    = 1 << 15          # 2^15 = pi у 16-бітному кутовому форматі
MIX_SHIFT   = 16               # мікшер: (x*lut) >> 16, підсилення 0.5 -- без насичення

ATAN_TAB = [int(round(math.atan(2.0 ** -i) / math.pi * ANGLE_PI)) for i in range(CORDIC_IT)]


def s16(v):  return ((v + 0x8000) & 0xFFFF) - 0x8000
def s32(v):  return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000
def u32(v):  return v & 0xFFFFFFFF


def load_lut(path):
    lut = []
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if line:
                lut.append(s16(int(line, 16)))
    assert len(lut) == NCO_LUT_N, "очікується 1024 записи"
    return lut


def cordic_atan2(y, x):
    """Vectoring CORDIC: кут вектора (x, y) у форматі 2^15 = pi. Вхід -- 18-бітні знакові."""
    if x == 0 and y == 0:
        return 0
    z = 0
    if x < 0:
        x, y, z = -x, -y, ANGLE_PI          # поворот на pi, далі працюємо в правій півплощині
    for i in range(CORDIC_IT):
        if y >= 0:
            x, y, z = x + (y >> i), y - (x >> i), z + ATAN_TAB[i]
        else:
            x, y, z = x - (y >> i), y + (x >> i), z - ATAN_TAB[i]
    return s16(z)


def normalize_pair(dot, cross, width=18):
    """Як у RTL: 34-бітний контейнер, зсув уліво, доки max(|dot|,|cross|) не займе
    біт 32, потім беремо біти [33:16] -> `width` знакових біт. Амплітудна
    незалежність для CORDIC без переповнення навіть у кутових випадках."""
    m = max(abs(dot), abs(cross))
    if m == 0:
        return 0, 0
    sh = 0
    while m < (1 << 32):
        m <<= 1
        sh += 1
    dot_n = (dot << sh) >> (34 - width)
    cross_n = (cross << sh) >> (34 - width)
    return dot_n, cross_n


# ------------------------------------------------------------------ модель ---
class DemodModel:
    def __init__(self, lut, nco_inc, decim=16, cic_shift=12, burst_thr=0,
                 bit_inc=4475, sync_word=0x91D3, pkt_len=48, crc_poly=0x1021,
                 crc_init=0xFFFF, crc_residue=0x0000, freq_init=0, afc_shift=5):
        self.lut = lut
        self.nco_inc = u32(nco_inc)
        self.decim = decim
        self.cic_shift = cic_shift
        self.burst_thr = burst_thr
        self.bit_inc = bit_inc
        self.sync_word = sync_word
        self.pkt_len = pkt_len
        self.crc_poly = crc_poly
        self.crc_init = crc_init
        self.crc_residue = crc_residue
        self.freq_init = freq_init
        self.afc_shift = afc_shift
        self.reset()

    def reset(self):
        self.phase = 0
        self.i1 = self.i2 = self.i3 = 0
        self.dec_cnt = 0
        self.c1 = self.c2 = self.c3 = 0           # попередні значення для comb
        self.ip = self.qp = 0
        self.pavg = 0
        self.noise = 0xFFFFFFFF
        self.warmup = 1024
        self.burst = False
        self.burst_len = 0
        self.burst_peak = 0
        self.favg = 0                              # 24-бітний акумулятор (8 дробових біт)
        self.dev = 0
        self.synced = False
        self.inverted = False
        self.preamble = False
        self.bit_prev = 0
        self.bit_phase = 0
        self.hist = 0
        self.pre_window = False
        # вікно вимірювання: від першого до останнього переходу в чергуванні преамбули
        self.win_started = False
        self.win_cnt = 0
        self.win_trans = 0
        self.win_fsum = 0
        self.win_cnt_snap = 0
        self.win_fsum_snap = 0
        self.win_frozen = False
        self.burst_pwr = 0                         # повільне середнє потужності у пакеті
        self.pkts_in_burst = 0
        self.pkt_active = False
        self.byte_sh = 0
        self.bit_in_byte = 0
        self.byte_cnt = 0
        self.crc = 0
        self.pkt = bytearray()
        self.results = []
        self.stats = {"bursts": 0, "packets": 0, "crc_ok": 0, "crc_err": 0}
        self.n_in = 0
        self.n_dec = 0
        self.trace = []

    # -------------------------------------------------------------------
    def thr_on(self):
        if self.burst_thr:
            return self.burst_thr
        return max(min(self.noise << 3, 0xFFFFFFFF), 64)

    def latch(self, kind):
        r = {
            "kind": kind,                      # "packet" | "burst_nosync" | "truncated"
            "at_dec_sample": self.n_dec,
            "burst_len": self.burst_len,
            "burst_peak": self.burst_peak,
            "burst_pwr": self.burst_pwr,
            "noise": self.noise,
            "preamble": self.preamble,
            "sync": self.synced or kind == "packet" or kind == "truncated",
            "inverted": self.inverted,
            "freq_est": s16(self.favg >> 8),
            "dev_est": self.dev >> 8,
            "win_trans": self.win_trans,
            "win_cnt": self.win_cnt_snap,
            "win_fsum": self.win_fsum_snap,
            "bits": self.byte_cnt * 8 + self.bit_in_byte,
            "crc_ok": (kind == "packet") and (self.crc == self.crc_residue),
            "payload": bytes(self.pkt),
        }
        self.results.append(r)

    # -------------------------------------------------------------------
    def push(self, I, Q):
        """Один вхідний комплексний відлік (int16, int16)."""
        self.n_in += 1
        idx = self.phase >> 22
        s = self.lut[idx]
        c = self.lut[(idx + 256) & (NCO_LUT_N - 1)]
        self.phase = u32(self.phase + self.nco_inc)
        mi = (I * c - Q * s) >> MIX_SHIFT
        mq = (I * s + Q * c) >> MIX_SHIFT

        # CIC: 3 інтегратори на повній швидкості (32-біт з переповненням).
        # Оновлення паралельне, як регістри в RTL: кожен каскад бере СТАРЕ
        # значення попереднього.
        i1, i2, i3 = self.i1, self.i2, self.i3
        q1, q2, q3 = getattr(self, "q1", 0), getattr(self, "q2", 0), getattr(self, "q3", 0)
        self.i1 = s32(i1 + mi); self.i2 = s32(i2 + i1); self.i3 = s32(i3 + i2)
        self.q1 = s32(q1 + mq); self.q2 = s32(q2 + q1); self.q3 = s32(q3 + q2)
        self.dec_cnt += 1
        if self.dec_cnt < self.decim:
            return
        self.dec_cnt = 0

        # comb x3 на децимованій швидкості
        def comb(name, x):
            st = getattr(self, name, [0, 0, 0])
            d1 = s32(x - st[0]); d2 = s32(d1 - st[1]); d3 = s32(d2 - st[2])
            setattr(self, name, [x, d1, d2])
            return d3
        di = comb("comb_i", self.i3) >> self.cic_shift
        dq = comb("comb_q", self.q3) >> self.cic_shift
        di = max(-32768, min(32767, di)); dq = max(-32768, min(32767, dq))
        self.step_dec(di, dq)

    # -------------------------------------------------------------------
    def step_dec(self, i, q):
        self.n_dec += 1
        # --- потужність і детектор пакета
        p = u32(i * i + q * q)
        self.pavg = u32(self.pavg + ((p - self.pavg) >> 4))      # python >> -- арифметичний
        thr = self.thr_on()                                      # як у RTL: поріг від поточного noise
        if not self.burst:
            sh = 4 if self.warmup else 8
            self.noise = u32(self.noise + ((self.pavg - self.noise) >> sh))
            if self.warmup:
                self.warmup -= 1
        burst_prev = self.burst
        if not self.burst and self.pavg > thr:
            self.burst = True
        elif self.burst and self.pavg < (thr >> 1):
            self.burst = False
        burst_start = self.burst and not burst_prev
        burst_end = (not self.burst) and burst_prev

        # --- дискримінатор: стан ip/qp оновлюється на КОЖНОМУ відліку
        dot = i * self.ip + q * self.qp
        cross = q * self.ip - i * self.qp
        self.ip, self.qp = i, q
        dn, cn = normalize_pair(dot, cross)
        dphi = cordic_atan2(cn, dn)

        if self.trace is not None:
            self.trace.append((i, q, dphi, self.pavg, int(self.burst)))

        if burst_start:                                          # початок пакета
            self.stats["bursts"] += 1
            self.burst_len = 0
            self.burst_peak = 0
            self.burst_pwr = self.pavg
            self.favg = s16(self.freq_init) << 8
            self.dev = 0
            self.synced = self.inverted = self.preamble = False
            self.pkt_active = False
            self.pkts_in_burst = 0
            self.hist = 0
            self.pre_window = False
            self.win_started = self.win_frozen = False
            self.win_cnt = self.win_trans = self.win_fsum = 0
            self.win_cnt_snap = self.win_fsum_snap = 0
            self.bit_phase = 0
            self.bit_prev = 0
            return                                               # як у RTL: стартовий відлік не обробляємо
        if burst_end:                                            # кінець пакета
            if self.pkt_active:
                self.latch("truncated")
            elif not self.synced and self.pkts_in_burst == 0:
                self.latch("burst_nosync")
            self.pkt_active = False
            self.synced = False

        if not self.burst:
            return
        self.burst_len += 1
        if self.pavg > self.burst_peak:
            self.burst_peak = self.pavg
        self.burst_pwr = u32(self.burst_pwr + ((self.pavg - self.burst_pwr) >> 6))

        # --- AFC / слайсер: швидко на старті пакета, далі повільно (менший ripple)
        favg16 = s16(self.favg >> 8)
        if not self.synced:
            sh = 4 if self.burst_len < 128 else 7
            self.favg = self.favg + (((dphi << 8) - self.favg) >> sh)
            self.favg = ((self.favg + (1 << 23)) & 0xFFFFFF) - (1 << 23)
            err = abs(dphi - favg16)
            self.dev = self.dev + (((err << 8) - self.dev) >> 5)
        bit = (1 if dphi > favg16 else 0) ^ (1 if self.inverted else 0)
        trans = bit != self.bit_prev
        self.bit_prev = bit

        # --- вікно вимірювання бітрейту й несучої: рахуємо лише між переходами,
        #     поки останні 8 біт чергуються (преамбула). Знімки беруться на переході,
        #     тож у вікні завжди ціле число бітових інтервалів.
        if not self.synced and self.pre_window and not self.win_frozen:
            if trans:
                if not self.win_started:
                    self.win_started = True
                    self.win_cnt = self.win_trans = self.win_fsum = 0
                else:
                    self.win_trans += 1
                    self.win_cnt_snap = self.win_cnt
                    self.win_fsum_snap = self.win_fsum
            if self.win_started:
                self.win_cnt += 1
                self.win_fsum = s32(self.win_fsum + dphi)

        # --- відновлення бітового такту
        if trans:
            e = s16(self.bit_phase - 0x8000)
            self.bit_phase = (self.bit_phase - (e >> 2)) & 0xFFFF
        nxt = self.bit_phase + self.bit_inc
        wrap = nxt > 0xFFFF
        self.bit_phase = nxt & 0xFFFF
        if not wrap:
            return

        # --- вибірка біта
        self.hist = ((self.hist << 1) | bit) & 0xFFFFFFFF
        h16 = self.hist & 0xFFFF
        if not self.synced:
            alt = (self.hist & 0xFF) in (0xAA, 0x55)
            if self.win_started and not alt:
                self.win_frozen = True            # чергування скінчилося -> вікно закрите
            self.pre_window = alt
            if h16 in (0xAAAA, 0x5555):
                self.preamble = True
            if h16 == self.sync_word or h16 == (~self.sync_word & 0xFFFF):
                if h16 != self.sync_word:
                    self.inverted = not self.inverted
                self.synced = True
                self.pkt_active = True
                self.byte_sh = 0; self.bit_in_byte = 0; self.byte_cnt = 0
                self.crc = self.crc_init
                self.pkt = bytearray()
                self.sync_freq = s16(self.favg >> 8)
            return

        if self.pkt_active:
            self.byte_sh = ((self.byte_sh << 1) | bit) & 0xFF
            fb = ((self.crc >> 15) & 1) ^ bit
            self.crc = ((self.crc << 1) & 0xFFFF) ^ (self.crc_poly if fb else 0)
            self.bit_in_byte += 1
            if self.bit_in_byte == 8:
                self.bit_in_byte = 0
                self.pkt.append(self.byte_sh)
                self.byte_cnt += 1
                if self.byte_cnt == self.pkt_len:
                    self.stats["packets"] += 1
                    self.pkts_in_burst += 1
                    ok = self.crc == self.crc_residue
                    self.stats["crc_ok" if ok else "crc_err"] += 1
                    self.latch("packet")
                    self.pkt_active = False
                    self.synced = False       # шукаємо наступний sync у тому ж пакеті


# ------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iq")
    ap.add_argument("--lut", default=os.path.join(os.path.dirname(__file__), "..",
                                                   "vivado", "sources", "mem", "nco_sin_1024.mem"))
    ap.add_argument("--fs", type=float, default=None)
    ap.add_argument("--nco-hz", type=float, default=None,
                    help="частота зсуву NCO (за замовчуванням з .json: LO - channel)")
    ap.add_argument("--decim", type=int, default=16)
    ap.add_argument("--bitrate", type=float, default=19200)
    ap.add_argument("--burst-thr", type=int, default=0, help="0 = авто (8 x шум)")
    ap.add_argument("--pkt-len", type=int, default=None)
    ap.add_argument("--max-samples", type=int, default=0)
    ap.add_argument("--dump", default=None, help="записати трасу децимованих відліків")
    ap.add_argument("--expect", default=None, help="записати очікувані результати для TB (txt)")
    args = ap.parse_args()

    meta = {}
    if os.path.exists(args.iq + ".json"):
        meta = json.load(open(args.iq + ".json"))
    fs = args.fs or meta.get("fs_hz", 4.5e6)
    if args.nco_hz is None:
        nco_hz = meta.get("lo_hz", 867.4e6) - meta.get("channel_hz", 866.31e6)
    else:
        nco_hz = args.nco_hz
    pkt_len = args.pkt_len or meta.get("packet_bytes_after_sync", 48)
    fs_dec = fs / args.decim
    nco_inc = int(round(nco_hz / fs * 2 ** 32))
    bit_inc = int(round(args.bitrate / fs_dec * 65536))
    cic_shift = 3 * int(round(math.log2(args.decim)))

    print(f"Fs={fs / 1e6:.3f} MHz  decim={args.decim}  Fs_dec={fs_dec / 1e3:.2f} kHz")
    print(f"NCO: {nco_hz / 1e3:+.1f} kHz -> nco_inc=0x{nco_inc & 0xFFFFFFFF:08X}")
    print(f"bit_inc={bit_inc}  cic_shift={cic_shift}  pkt_len={pkt_len}")

    lut = load_lut(args.lut)
    m = DemodModel(lut, nco_inc, decim=args.decim, cic_shift=cic_shift,
                   burst_thr=args.burst_thr, bit_inc=bit_inc, pkt_len=pkt_len)
    if not args.dump:
        m.trace = None

    data = open(args.iq, "rb").read()
    n = len(data) // 4
    if args.max_samples:
        n = min(n, args.max_samples)
    vals = struct.unpack("<%dh" % (2 * n), data[:4 * n])
    for k in range(n):
        m.push(vals[2 * k], vals[2 * k + 1])

    print(f"\nвхідних відліків: {m.n_in}, децимованих: {m.n_dec}")
    print(f"шум (noise floor): {m.noise}  поточний поріг: {m.thr_on()}")
    print(f"статистика: {m.stats}\n")

    expected = [bytes.fromhex(p["payload_hex"]) + struct.pack(">H", p["crc16"])
                for p in meta.get("packets", [])]
    ok_all = True
    for r in m.results:
        f_slicer = r["freq_est"] / 32768 * fs_dec / 2
        f_res = (r["win_fsum"] / r["win_cnt"] / 32768 * fs_dec / 2) if r["win_cnt"] else 0.0
        dev = r["dev_est"] / 32768 * fs_dec / 2
        br = fs_dec * r["win_trans"] / r["win_cnt"] if r["win_cnt"] else 0
        snr = 10 * math.log10(max(r["burst_pwr"] - r["noise"], 1) / max(r["noise"], 1))
        print(f"[{r['kind']:12s}] @dec {r['at_dec_sample']:7d}  burst_len={r['burst_len']:5d}  "
              f"preamble={int(r['preamble'])} sync={int(r['sync'])} inv={int(r['inverted'])} "
              f"crc_ok={int(r['crc_ok'])} bits={r['bits']}")
        print(f"    f_residual={f_res / 1e3:+.2f} kHz (slicer {f_slicer / 1e3:+.2f})  "
              f"dev={dev / 1e3:.1f} kHz  bitrate={br:.0f} ({r['win_trans']} bits)  "
              f"SNR~{snr:.1f} dB  pwr={r['burst_pwr']} peak={r['burst_peak']} noise={r['noise']}")
        if r["kind"] == "packet":
            print(f"    payload: {r['payload'][:16].hex()}... "
                  f"ascii='{r['payload'][:12].decode('ascii', 'replace')}'")
            if expected:
                match = r["payload"] in expected
                print(f"    збіг з очікуваним: {'ТАК' if match else 'НІ'}")
                ok_all &= match and r["crc_ok"]

    if expected:
        got = sum(1 for r in m.results if r["kind"] == "packet" and r["crc_ok"])
        print(f"\nпакетів із правильним CRC: {got}/{len(expected)} -> "
              f"{'PASS' if ok_all and got == len(expected) else 'FAIL'}")

    if args.dump and m.trace:
        with open(args.dump, "w") as f:
            for t in m.trace:
                f.write("%d %d %d %u %d\n" % t)
        print("траса ->", args.dump)

    if args.expect:
        with open(args.expect, "w") as f:
            f.write(f"# nco_inc decim cic_shift bit_inc pkt_len\n")
            f.write(f"{nco_inc & 0xFFFFFFFF:08x} {args.decim} {cic_shift} {bit_inc} {pkt_len}\n")
            for r in m.results:
                if r["kind"] == "packet":
                    f.write(f"P {int(r['crc_ok'])} {r['payload'].hex()}\n")
                else:
                    f.write(f"B {r['kind']}\n")
        print("очікування для TB ->", args.expect)
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
