#!/usr/bin/env python3
"""
Run the RTL FSK demodulator and plot all visible datapath stages.

Default flow:
  1. Use vivado/sources/sim_data/sim.iq if present, or generate I/Q with iqgen.py.
  2. Run demod_model.py to produce matching RTL configuration.
  3. Compile and run tb_fsk_demod_plot in XSIM.
  4. Read rtl_plot.csv and save a multi-panel HTML plot.

Examples:
  python tools/plot_rtl_demod.py
  python tools/plot_rtl_demod.py --iq vivado/sources/sim_data/sim.iq
  python tools/plot_rtl_demod.py --show
"""
from __future__ import annotations

import argparse
import cmath
import csv
import importlib.util
import math
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
RTL = ROOT / "vivado" / "sources" / "rtl"
TB = ROOT / "vivado" / "sources" / "tb"
MEM = ROOT / "vivado" / "sources" / "mem"
SIM_DATA = ROOT / "vivado" / "sources" / "sim_data"
SIM_WORK = ROOT / "vivado" / "sim_plot_work"


SV_SOURCES = [
    RTL / "demod_cordic_atan2.sv",
    RTL / "demod_nco_mixer.sv",
    RTL / "demod_cic3.sv",
    RTL / "demod_discriminator.sv",
    RTL / "demod_power.sv",
    RTL / "demod_bit_decoder.sv",
    RTL / "fsk_demod_top.sv",
    TB / "tb_fsk_demod_plot.sv",
]


def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    print("$", " ".join(cmd))
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=check)


def as_posix(p: Path) -> str:
    return p.resolve().as_posix()


def find_tool(name: str) -> str:
    tool = shutil.which(name)
    if tool is None:
        raise SystemExit(f"ERROR: {name} is not in PATH. Source Vivado settings first.")
    return tool


def generate_iq(iq: Path, seconds: float, bursts: int, snr: float, no_noise: bool) -> None:
    if importlib.util.find_spec("numpy") is None:
        raise SystemExit(
            "ERROR: numpy is required only to generate a new I/Q file with iqgen.py. "
            "Use --iq vivado/sources/sim_data/sim.iq or install numpy."
        )
    args = [
        sys.executable,
        str(TOOLS / "iqgen.py"),
        "--out",
        str(iq),
        "--seconds",
        str(seconds),
        "--bursts",
        str(bursts),
        "--snr",
        str(snr),
        "--seed",
        "7",
    ]
    if no_noise:
        args.append("--no-noise")
    run(args, cwd=ROOT)


def make_expect(iq: Path, trace: Path, expect: Path) -> tuple[str, int, int, int, int]:
    run([
        sys.executable,
        str(TOOLS / "demod_model.py"),
        str(iq),
        "--dump",
        str(trace),
        "--expect",
        str(expect),
    ], cwd=ROOT)

    lines = [line.strip() for line in expect.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.startswith("#")]
    if not lines:
        raise SystemExit(f"ERROR: no config line found in {expect}")
    nco_hex, decim, cic_shift, bit_inc, pkt_len = lines[0].split()[:5]
    return nco_hex, int(decim), int(cic_shift), int(bit_inc), int(pkt_len)


def run_rtl(iq: Path, csv_path: Path, cfg: tuple[str, int, int, int, int], max_samples: int) -> None:
    xvlog = find_tool("xvlog")
    xelab = find_tool("xelab")
    xsim = find_tool("xsim")

    SIM_WORK.mkdir(parents=True, exist_ok=True)
    shutil.copy2(MEM / "nco_sin_1024.mem", SIM_WORK / "nco_sin_1024.mem")

    nco_hex, decim, cic_shift, bit_inc, pkt_len = cfg
    (SIM_WORK / "plot_run_args.txt").write_text(
        f"{as_posix(iq)}\n"
        f"{as_posix(csv_path)}\n"
        f"{nco_hex} {decim} {cic_shift} {bit_inc} {pkt_len} {max_samples}\n",
        encoding="ascii",
    )

    xvlog_cmd = [xvlog, "-sv"] + [str(p) for p in SV_SOURCES]
    run(xvlog_cmd, cwd=SIM_WORK)
    run([xelab, "-debug", "typical", "tb_fsk_demod_plot", "-s", "tb_fsk_demod_plot_sim"], cwd=SIM_WORK)
    run([xsim, "tb_fsk_demod_plot_sim", "-R"], cwd=SIM_WORK)


def read_csv(path: Path) -> dict[str, list[int]]:
    def to_int(value: str) -> int:
        return 0 if value.lower().startswith(("x", "z")) else int(value)

    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        cols: dict[str, list[int]] = {name: [] for name in reader.fieldnames or []}
        for row in reader:
            for name, value in row.items():
                cols[name].append(to_int(value))
    if not cols or not cols.get("cycle"):
        raise SystemExit(f"ERROR: {path} is empty")
    return cols


def thin(x: list[int], y: list[int], max_points: int = 12000) -> tuple[list[int], list[int]]:
    if len(x) <= max_points:
        return x, y
    step = int(math.ceil(len(x) / max_points))
    return x[::step], y[::step]


def stage(data: dict[str, list[int]], valid_name: str, names: list[str]) -> tuple[list[int], list[list[int]]]:
    idx = [i for i, v in enumerate(data[valid_name]) if v != 0]
    x = [data["cycle"][i] for i in idx]
    return x, [[data[name][i] for i in idx] for name in names]


def html_escape(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def ascii_preview(payload_hex: str, limit: int = 16) -> str:
    try:
        raw = bytes.fromhex(payload_hex[:limit * 2])
    except ValueError:
        return ""
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in raw)
    return text + ("..." if len(payload_hex) > limit * 2 else "")


def read_expect_packets(expect_path: Path) -> list[dict[str, str]]:
    if not expect_path.exists():
        return []
    packets = []
    for line in expect_path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) >= 3 and parts[0] == "P":
            packets.append({
                "crc": "OK" if parts[1] == "1" else "ERR",
                "payload": parts[2],
                "ascii": ascii_preview(parts[2]),
            })
    return packets


def result_events(data: dict[str, list[int]]) -> list[dict[str, int]]:
    events = []
    for i, strobe in enumerate(data.get("res_strobe", [])):
        if strobe:
            events.append({
                "cycle": data["cycle"][i],
                "kind": data["res_kind"][i],
                "crc": data["res_crc_ok"][i],
                "bits": data["res_bits"][i],
                "bytes": data["res_bytes"][i],
                "in_count": data["in_count"][i],
                "dec_count": data["dec_count"][i],
            })
    return events


def burst_input_windows(data: dict[str, list[int]], total_samples: int,
                        margin: int = 4096) -> list[tuple[int, int]]:
    windows = []
    start = None
    for i, value in enumerate(data.get("burst_start", [])):
        if value:
            start = data["in_count"][i]
        if data.get("burst_end", [])[i] and start is not None:
            end = data["in_count"][i]
            lo = max(0, start - margin)
            hi = min(total_samples, end + margin)
            if hi > lo:
                windows.append((lo, hi))
            start = None
    return windows


def fft_inplace(values: list[complex]) -> None:
    n = len(values)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            values[i], values[j] = values[j], values[i]

    size = 2
    while size <= n:
        half = size // 2
        step = cmath.exp(-2j * math.pi / size)
        for start in range(0, n, size):
            w = 1 + 0j
            for k in range(half):
                even = values[start + k]
                odd = values[start + k + half] * w
                values[start + k] = even + odd
                values[start + k + half] = even - odd
                w *= step
        size *= 2


def spectrogram_matrix(i_vals: list[int], q_vals: list[int], fft_size: int = 512,
                       max_frames: int = 320, bins_out: int = 180) -> tuple[list[list[float]], float, float]:
    n = min(len(i_vals), len(q_vals))
    if n < fft_size:
        return [], -0.5, 0.5
    hop = max(fft_size // 4, (n - fft_size) // max(1, max_frames - 1))
    window = [0.5 - 0.5 * math.cos(2 * math.pi * k / (fft_size - 1)) for k in range(fft_size)]
    full_rows = []
    for start in range(0, n - fft_size + 1, hop):
        frame = [complex(i_vals[start + k], q_vals[start + k]) * window[k] for k in range(fft_size)]
        fft_inplace(frame)
        shifted = frame[fft_size // 2:] + frame[:fft_size // 2]
        mags = [20.0 * math.log10(abs(v) + 1.0) for v in shifted]
        full_rows.append(mags)
        if len(full_rows) >= max_frames:
            break

    frame_peaks = [(max(row), max(range(fft_size), key=lambda idx: row[idx])) for row in full_rows]
    top_peak = max(level for level, _ in frame_peaks)
    active_peaks = [idx for level, idx in frame_peaks if level >= top_peak - 20.0]
    if active_peaks:
        lo = max(0, min(active_peaks) - 36)
        hi = min(fft_size, max(active_peaks) + 37)
    else:
        _, peak_idx = max(frame_peaks)
        lo = max(0, peak_idx - 56)
        hi = min(fft_size, peak_idx + 57)
    if hi - lo < 80:
        center = (lo + hi) // 2
        lo = max(0, center - 40)
        hi = min(fft_size, lo + 80)
        lo = max(0, hi - 80)

    cropped_rows = [row[lo:hi] for row in full_rows]
    crop_bins = hi - lo
    if bins_out < crop_bins:
        group = crop_bins / bins_out
        reduced_rows = []
        for row in cropped_rows:
            reduced = []
            for b in range(bins_out):
                r_lo = int(b * group)
                r_hi = max(r_lo + 1, int((b + 1) * group))
                reduced.append(max(row[r_lo:r_hi]))
            reduced_rows.append(reduced)
        cropped_rows = reduced_rows

    f_min = lo / fft_size - 0.5
    f_max = hi / fft_size - 0.5
    return cropped_rows, f_min, f_max


def heat_color(v: float) -> str:
    v = max(0.0, min(1.0, v))
    stops = [
        (15, 23, 42),
        (30, 64, 175),
        (14, 165, 233),
        (34, 197, 94),
        (250, 204, 21),
        (239, 68, 68),
    ]
    pos = v * (len(stops) - 1)
    idx = min(int(pos), len(stops) - 2)
    frac = pos - idx
    r0, g0, b0 = stops[idx]
    r1, g1, b1 = stops[idx + 1]
    r = round(r0 + (r1 - r0) * frac)
    g = round(g0 + (g1 - g0) * frac)
    b = round(b0 + (b1 - b0) * frac)
    return f"#{r:02x}{g:02x}{b:02x}"


def normalize_db(rows: list[list[float]]) -> list[list[float]]:
    vals = [v for row in rows for v in row]
    if not vals:
        return []
    top = max(vals)
    floor = top - 38.0
    span = max(top - floor, 1.0)
    return [[(v - floor) / span for v in row] for row in rows]


def svg_spectrogram(title: str, i_vals: list[int], q_vals: list[int],
                    width: int = 1200, height: int = 420) -> str:
    rows, f_min, f_max = spectrogram_matrix(i_vals, q_vals)
    norm = normalize_db(rows)
    if not norm:
        return ""
    pad_l, pad_r, pad_t, pad_b = 56, 22, 22, 38
    plot_w = width - pad_l - pad_r
    plot_h = height - pad_t - pad_b
    frame_count = len(norm)
    bin_count = len(norm[0])
    cell_w = plot_w / frame_count
    cell_h = plot_h / bin_count
    rects = []
    ridge_pts = []
    for x_idx, row in enumerate(norm):
        x = pad_l + x_idx * cell_w
        peak_bin = max(range(bin_count), key=lambda idx: row[idx])
        ridge_pts.append(f"{x + cell_w / 2:.1f},{pad_t + (bin_count - 1 - peak_bin + 0.5) * cell_h:.1f}")
        for b_idx, val in enumerate(row):
            y = pad_t + (bin_count - 1 - b_idx) * cell_h
            rects.append(
                f'<rect x="{x:.2f}" y="{y:.2f}" width="{cell_w + 0.15:.2f}" '
                f'height="{cell_h + 0.15:.2f}" fill="{heat_color(val)}"/>'
            )
    return f"""
    <section class="panel">
      <h2>{html_escape(title)}</h2>
      <svg viewBox="0 0 {width} {height}" role="img" aria-label="{html_escape(title)}">
        <rect x="0" y="0" width="{width}" height="{height}" class="bg"/>
        <rect x="{pad_l}" y="{pad_t}" width="{plot_w}" height="{plot_h}" class="frame"/>
        {''.join(rects)}
        <rect x="{pad_l}" y="{pad_t}" width="{plot_w}" height="{plot_h}" class="frame" fill="none"/>
        <polyline points="{" ".join(ridge_pts)}" fill="none" stroke="#0f172a" stroke-width="1.4" opacity="0.78"/>
        <text x="{width / 2:.1f}" y="{height - 8}" class="axis-label">time, input samples</text>
        <text x="12" y="{height / 2:.1f}" class="axis-label vertical">zoomed frequency, Fs normalized</text>
        <text x="{pad_l - 52}" y="{pad_t + 5}" class="scale">{f_max:+.3f}</text>
        <text x="{pad_l - 52}" y="{pad_t + plot_h:.1f}" class="scale">{f_min:+.3f}</text>
      </svg>
    </section>
    """


def svg_waterfall(title: str, i_vals: list[int], q_vals: list[int],
                  width: int = 1200, height: int = 420) -> str:
    rows, _, _ = spectrogram_matrix(i_vals, q_vals, max_frames=220, bins_out=120)
    norm = normalize_db(rows)
    if not norm:
        return ""
    pad_l, pad_r, pad_t, pad_b = 56, 28, 26, 34
    plot_w = width - pad_l - pad_r
    plot_h = height - pad_t - pad_b
    take = min(36, len(norm))
    step = max(1, len(norm) // take)
    selected = norm[::step][:take]
    lines = []
    for idx, row in enumerate(selected):
        y_base = pad_t + idx * (plot_h / max(1, take - 1))
        x_shift = idx * 6.0
        pts = []
        for b_idx, val in enumerate(row):
            x = pad_l + x_shift + b_idx * (plot_w - take * 6.0) / max(1, len(row) - 1)
            y = y_base - val * 34.0
            pts.append(f"{x:.1f},{y:.1f}")
        color = heat_color(idx / max(1, take - 1))
        lines.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="{color}" stroke-width="1.1"/>')
    return f"""
    <section class="panel">
      <h2>{html_escape(title)}</h2>
      <svg viewBox="0 0 {width} {height}" role="img" aria-label="{html_escape(title)}">
        <rect x="0" y="0" width="{width}" height="{height}" class="bg"/>
        <line x1="{pad_l}" y1="{height-pad_b}" x2="{width-pad_r}" y2="{height-pad_b}" class="axis"/>
        <line x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" y2="{height-pad_b}" class="axis"/>
        {''.join(lines)}
        <text x="{width / 2:.1f}" y="{height - 8}" class="axis-label">frequency bins, older traces at top</text>
        <text x="12" y="{height / 2:.1f}" class="axis-label vertical">power, dB relative</text>
      </svg>
    </section>
    """


def points_for_line(x: list[int], y: list[int], width: int, height: int, pad: int,
                    y_min: float, y_max: float) -> str:
    if not x:
        return ""
    x_min, x_max = min(x), max(x)
    if x_max == x_min:
        x_max = x_min + 1
    if y_max == y_min:
        y_max = y_min + 1
    pts = []
    for xv, yv in zip(x, y):
        px = pad + (xv - x_min) * (width - 2 * pad) / (x_max - x_min)
        py = height - pad - (yv - y_min) * (height - 2 * pad) / (y_max - y_min)
        pts.append(f"{px:.1f},{py:.1f}")
    return " ".join(pts)


def svg_line_panel(title: str, series: list[tuple[str, list[int], list[int], str]],
                   width: int = 1200, height: int = 260) -> str:
    pad = 42
    ys = [v for _, _, y, _ in series for v in y]
    y_min = min(ys) if ys else 0
    y_max = max(ys) if ys else 1
    if y_min == y_max:
        y_min -= 1
        y_max += 1
    grid = []
    for k in range(5):
        gy = pad + k * (height - 2 * pad) / 4
        grid.append(f'<line x1="{pad}" y1="{gy:.1f}" x2="{width-pad}" y2="{gy:.1f}" class="grid"/>')
    lines = []
    legend = []
    for n, (label, x, y, color) in enumerate(series):
        xt, yt = thin(x, y, 5000)
        pts = points_for_line(xt, yt, width, height, pad, y_min, y_max)
        lines.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="1.2"/>')
        legend.append(f'<span><i style="background:{color}"></i>{html_escape(label)}</span>')
    return f"""
    <section class="panel">
      <h2>{html_escape(title)}</h2>
      <div class="legend">{''.join(legend)}</div>
      <svg viewBox="0 0 {width} {height}" role="img" aria-label="{html_escape(title)}">
        <rect x="0" y="0" width="{width}" height="{height}" class="bg"/>
        {''.join(grid)}
        <line x1="{pad}" y1="{height-pad}" x2="{width-pad}" y2="{height-pad}" class="axis"/>
        <line x1="{pad}" y1="{pad}" x2="{pad}" y2="{height-pad}" class="axis"/>
        <text x="{pad}" y="24" class="scale">max {y_max:.0f}</text>
        <text x="{pad}" y="{height-8}" class="scale">min {y_min:.0f}</text>
        {''.join(lines)}
      </svg>
    </section>
    """


def svg_constellation(title: str, i_vals: list[int], q_vals: list[int],
                      width: int = 1200, height: int = 320) -> str:
    pad = 42
    step = max(1, len(i_vals) // 6000)
    pts_i = i_vals[::step]
    pts_q = q_vals[::step]
    if not pts_i:
        return svg_line_panel(title, [])
    x_min, x_max = min(pts_i), max(pts_i)
    y_min, y_max = min(pts_q), max(pts_q)
    if x_min == x_max:
        x_min -= 1
        x_max += 1
    if y_min == y_max:
        y_min -= 1
        y_max += 1
    circles = []
    for xv, yv in zip(pts_i, pts_q):
        px = pad + (xv - x_min) * (width - 2 * pad) / (x_max - x_min)
        py = height - pad - (yv - y_min) * (height - 2 * pad) / (y_max - y_min)
        circles.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="1.8"/>')
    return f"""
    <section class="panel">
      <h2>{html_escape(title)}</h2>
      <svg viewBox="0 0 {width} {height}" role="img" aria-label="{html_escape(title)}">
        <rect x="0" y="0" width="{width}" height="{height}" class="bg"/>
        <line x1="{pad}" y1="{height/2:.1f}" x2="{width-pad}" y2="{height/2:.1f}" class="grid"/>
        <line x1="{width/2:.1f}" y1="{pad}" x2="{width/2:.1f}" y2="{height-pad}" class="grid"/>
        <g class="dots">{''.join(circles)}</g>
      </svg>
    </section>
    """


def svg_decode_panel(data: dict[str, list[int]], expect_path: Path,
                     width: int = 1200, height: int = 260) -> str:
    pad = 42
    cycles = data["cycle"]
    if not cycles:
        return ""
    x_min, x_max = min(cycles), max(cycles)
    if x_min == x_max:
        x_max = x_min + 1

    def px(cycle: int) -> float:
        return pad + (cycle - x_min) * (width - 2 * pad) / (x_max - x_min)

    def points_for_state(name: str, level: int) -> str:
        x, y = thin(cycles, [level if v else 0 for v in data[name]], 7000)
        pts = []
        for xv, yv in zip(x, y):
            py = height - pad - yv * (height - 2 * pad) / 3.2
            pts.append(f"{px(xv):.1f},{py:.1f}")
        return " ".join(pts)

    markers = []
    for idx, ev in enumerate(result_events(data), start=1):
        color = "#16a34a" if ev["crc"] else "#dc2626"
        x_pos = px(ev["cycle"])
        label = f"RTL PKT{idx - 1:02d} CRC {'OK' if ev['crc'] else 'ERR'}"
        markers.append(
            f'<line x1="{x_pos:.1f}" y1="{pad}" x2="{x_pos:.1f}" y2="{height-pad}" '
            f'stroke="{color}" stroke-width="2"/>'
            f'<text x="{x_pos + 5:.1f}" y="{pad + 18}" class="event">{html_escape(label)}</text>'
        )

    packets = read_expect_packets(expect_path)
    if packets:
        rows = []
        for idx, pkt in enumerate(packets):
            rows.append(
                f"<tr><td>PKT{idx:02d}</td><td>{pkt['crc']}</td>"
                f"<td><code>{html_escape(pkt['ascii'])}</code></td>"
                f"<td><code>{html_escape(pkt['payload'][:32])}...</code></td></tr>"
            )
        summary = (
            '<table class="decode"><thead><tr><th>packet</th><th>model CRC</th>'
            '<th>ASCII preview</th><th>payload hex</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table>"
        )
    else:
        summary = '<p class="meta">No model packet list was found.</p>'

    if not markers:
        summary += (
            '<p class="warn">No RTL <code>res_strobe</code> was present in this CSV. '
            'Run without <code>--max-samples</code>, or use a larger limit, to capture full packets.</p>'
        )

    return f"""
    <section class="panel">
      <h2>RTL decoder result timeline</h2>
      <div class="legend">
        <span><i style="background:#dc2626"></i>sync</span>
        <span><i style="background:#f59e0b"></i>preamble</span>
        <span><i style="background:#16a34a"></i>packet active</span>
        <span><i style="background:#0f172a"></i>result marker</span>
      </div>
      <svg viewBox="0 0 {width} {height}" role="img" aria-label="RTL decoder result timeline">
        <rect x="0" y="0" width="{width}" height="{height}" class="bg"/>
        <line x1="{pad}" y1="{height-pad}" x2="{width-pad}" y2="{height-pad}" class="axis"/>
        <line x1="{pad}" y1="{pad}" x2="{pad}" y2="{height-pad}" class="axis"/>
        <text x="{pad}" y="24" class="scale">cycles {x_min}..{x_max}</text>
        <polyline points="{points_for_state("synced", 1)}" fill="none" stroke="#dc2626" stroke-width="1.4"/>
        <polyline points="{points_for_state("preamble", 2)}" fill="none" stroke="#f59e0b" stroke-width="1.4"/>
        <polyline points="{points_for_state("pkt_active", 3)}" fill="none" stroke="#16a34a" stroke-width="1.8"/>
        {''.join(markers)}
      </svg>
      {summary}
    </section>
    """


def plot_html(csv_path: Path, out_html: Path) -> None:
    d = read_csv(csv_path)
    panels = []

    x, ys = stage(d, "in_valid", ["in_i", "in_q"])
    panels.append(svg_line_panel("Input I/Q from RTL test source", [
        ("I", x, ys[0], "#2563eb"),
        ("Q", x, ys[1], "#dc2626"),
    ]))
    windows = burst_input_windows(d, len(ys[0]))
    if windows:
        for idx, (lo, hi) in enumerate(windows[:4]):
            pkt_i = ys[0][lo:hi]
            pkt_q = ys[1][lo:hi]
            panels.append(svg_spectrogram(f"Packet {idx} I/Q spectrogram zoom", pkt_i, pkt_q))
            panels.append(svg_waterfall(f"Packet {idx} I/Q waterfall zoom", pkt_i, pkt_q))
    else:
        panels.append(svg_spectrogram("Input I/Q spectrogram", ys[0], ys[1]))
        panels.append(svg_waterfall("Input I/Q waterfall", ys[0], ys[1]))

    x, ys = stage(d, "mix_valid", ["mix_i", "mix_q"])
    panels.append(svg_line_panel("NCO mixer output", [
        ("mix I", x, ys[0], "#2563eb"),
        ("mix Q", x, ys[1], "#dc2626"),
    ]))

    x, ys = stage(d, "dec_valid", ["dec_i", "dec_q"])
    panels.append(svg_line_panel("CIC3 decimator output", [
        ("dec I", x, ys[0], "#2563eb"),
        ("dec Q", x, ys[1], "#dc2626"),
    ]))
    panels.append(svg_constellation("Decimated I/Q constellation", ys[0], ys[1]))

    x, ys = stage(d, "dsc_valid", ["dphi"])
    panels.append(svg_line_panel("FM discriminator dphi", [
        ("dphi", x, ys[0], "#7c3aed"),
    ]))

    x, ys = stage(d, "pw_valid", ["pavg", "noise", "thr_on", "burst"])
    burst_scaled = []
    if ys[0]:
        scale = max(max(ys[0]), 1)
        burst_scaled = [v * scale for v in ys[3]]
    panels.append(svg_line_panel("Power estimator and burst detector", [
        ("pavg", x, ys[0], "#0f766e"),
        ("noise", x, ys[1], "#64748b"),
        ("threshold", x, ys[2], "#f59e0b"),
        ("burst scaled", x, burst_scaled, "#dc2626"),
    ]))

    x, ys = stage(d, "pw_valid", ["pw_dphi", "favg", "dev", "synced", "preamble", "pkt_active"])
    state_scale = max([abs(v) for v in ys[0]] + [1])
    panels.append(svg_line_panel("Bit decoder input and state", [
        ("dphi", x, ys[0], "#7c3aed"),
        ("AFC/favg", x, ys[1], "#2563eb"),
        ("dev", x, ys[2], "#0f766e"),
        ("sync scaled", x, [v * state_scale for v in ys[3]], "#dc2626"),
        ("preamble scaled", x, [v * state_scale for v in ys[4]], "#f59e0b"),
        ("packet scaled", x, [v * state_scale for v in ys[5]], "#16a34a"),
    ]))
    panels.append(svg_decode_panel(d, SIM_DATA / "rtl_plot.expect.txt"))

    out_html.parent.mkdir(parents=True, exist_ok=True)
    out_html.write_text(f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DF5 RTL FSK demodulator plots</title>
  <style>
    body {{ margin: 24px; font: 14px/1.45 system-ui, Segoe UI, sans-serif; color: #111827; background: #f8fafc; }}
    h1 {{ margin: 0 0 8px; font-size: 24px; }}
    .meta {{ margin: 0 0 24px; color: #475569; }}
    .panel {{ margin: 0 0 22px; padding: 16px; background: white; border: 1px solid #dbe3ef; border-radius: 8px; }}
    h2 {{ margin: 0 0 8px; font-size: 16px; }}
    svg {{ width: 100%; height: auto; display: block; }}
    .bg {{ fill: #ffffff; }}
    .grid {{ stroke: #e2e8f0; stroke-width: 1; }}
    .axis {{ stroke: #94a3b8; stroke-width: 1; }}
    .frame {{ stroke: #94a3b8; stroke-width: 1; }}
    .scale {{ fill: #64748b; font-size: 12px; }}
    .axis-label {{ fill: #334155; font-size: 12px; text-anchor: middle; }}
    .vertical {{ transform: rotate(-90deg); transform-origin: 12px 50%; }}
    .legend {{ display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 8px; color: #334155; }}
    .legend i {{ display: inline-block; width: 12px; height: 12px; margin-right: 5px; vertical-align: -1px; border-radius: 2px; }}
    .dots circle {{ fill: #2563eb; opacity: 0.35; }}
    .event {{ fill: #0f172a; font-size: 12px; font-weight: 600; }}
    .warn {{ margin: 12px 0 0; color: #b45309; }}
    table.decode {{ width: 100%; margin-top: 12px; border-collapse: collapse; font-size: 13px; }}
    table.decode th, table.decode td {{ padding: 6px 8px; border-top: 1px solid #e2e8f0; text-align: left; }}
    code {{ font-family: Consolas, ui-monospace, monospace; }}
  </style>
</head>
<body>
  <h1>DF5 RTL FSK demodulator datapath</h1>
  <p class="meta">CSV: {html_escape(str(csv_path))}</p>
  {''.join(panels)}
</body>
</html>
""", encoding="utf-8")
    print("plot ->", out_html)


def plot_csv(csv_path: Path, out_png: Path, show: bool) -> None:
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit("ERROR: matplotlib is required for PNG output. Use --html output.html instead.") from exc

    d = read_csv(csv_path)

    fig, ax = plt.subplots(7, 1, figsize=(15, 18), sharex=False, constrained_layout=True)
    fig.suptitle("DF5 RTL FSK demodulator datapath", fontsize=15)

    x, ys = stage(d, "in_valid", ["in_i", "in_q"])
    xt, i_t = thin(x, ys[0])
    _, q_t = thin(x, ys[1])
    ax[0].plot(xt, i_t, label="I", linewidth=0.8)
    ax[0].plot(xt, q_t, label="Q", linewidth=0.8)
    ax[0].set_title("Input I/Q from Python FSK modulator")
    ax[0].set_ylabel("ADC LSB")
    ax[0].legend(loc="upper right")

    x, ys = stage(d, "mix_valid", ["mix_i", "mix_q"])
    xt, i_t = thin(x, ys[0])
    _, q_t = thin(x, ys[1])
    ax[1].plot(xt, i_t, label="mix I", linewidth=0.8)
    ax[1].plot(xt, q_t, label="mix Q", linewidth=0.8)
    ax[1].set_title("NCO mixer output")
    ax[1].set_ylabel("Q15")
    ax[1].legend(loc="upper right")

    x, ys = stage(d, "dec_valid", ["dec_i", "dec_q"])
    xt, i_t = thin(x, ys[0])
    _, q_t = thin(x, ys[1])
    ax[2].plot(xt, i_t, label="dec I", linewidth=0.8)
    ax[2].plot(xt, q_t, label="dec Q", linewidth=0.8)
    ax[2].set_title("CIC3 decimator output")
    ax[2].set_ylabel("Q15")
    ax[2].legend(loc="upper right")

    x, ys = stage(d, "dec_valid", ["dec_i", "dec_q"])
    ax[3].scatter(ys[0][::max(1, len(ys[0]) // 6000)], ys[1][::max(1, len(ys[1]) // 6000)],
                  s=3, alpha=0.35)
    ax[3].set_title("Decimated I/Q constellation")
    ax[3].set_xlabel("I")
    ax[3].set_ylabel("Q")
    ax[3].axis("equal")

    x, ys = stage(d, "dsc_valid", ["dphi"])
    xt, dphi_t = thin(x, ys[0])
    ax[4].plot(xt, dphi_t, color="tab:purple", linewidth=0.8)
    ax[4].set_title("FM discriminator dphi")
    ax[4].set_ylabel("angle Q15")

    x, ys = stage(d, "pw_valid", ["pavg", "noise", "thr_on", "burst"])
    xt, pavg_t = thin(x, ys[0])
    _, noise_t = thin(x, ys[1])
    _, thr_t = thin(x, ys[2])
    _, burst_t = thin(x, ys[3])
    ax[5].plot(xt, pavg_t, label="pavg", linewidth=0.8)
    ax[5].plot(xt, noise_t, label="noise", linewidth=0.8)
    ax[5].plot(xt, thr_t, label="threshold", linewidth=0.8)
    if len(pavg_t):
        scale = max(float(max(pavg_t)), 1.0)
        ax[5].fill_between(xt, 0, [v * scale for v in burst_t], alpha=0.15, label="burst")
    ax[5].set_title("Power estimator and burst detector")
    ax[5].set_ylabel("power")
    ax[5].legend(loc="upper right")

    x, ys = stage(d, "pw_valid", ["pw_dphi", "favg", "dev", "synced", "preamble", "pkt_active"])
    xt, pw_dphi_t = thin(x, ys[0])
    _, favg_t = thin(x, ys[1])
    _, dev_t = thin(x, ys[2])
    _, synced_t = thin(x, ys[3])
    _, preamble_t = thin(x, ys[4])
    _, pkt_t = thin(x, ys[5])
    ax[6].plot(xt, pw_dphi_t, label="dphi", linewidth=0.8)
    ax[6].plot(xt, favg_t, label="AFC/favg", linewidth=0.8)
    ax[6].plot(xt, dev_t, label="dev", linewidth=0.8)
    if len(pw_dphi_t):
        scale = max(float(max(abs(v) for v in pw_dphi_t)), 1.0)
        ax[6].fill_between(xt, 0, [v * scale for v in synced_t], alpha=0.12, label="sync")
        ax[6].fill_between(xt, 0, [v * scale for v in preamble_t], alpha=0.12, label="preamble")
        ax[6].fill_between(xt, 0, [v * scale for v in pkt_t], alpha=0.12, label="packet")
    ax[6].set_title("Bit decoder inputs and state")
    ax[6].set_xlabel("simulation cycle")
    ax[6].set_ylabel("Q15 / state")
    ax[6].legend(loc="upper right")

    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=150)
    print("plot ->", out_png)
    if show:
        plt.show()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iq", type=Path, default=None,
                    help="Existing int16 IQ file. Default: vivado/sources/sim_data/sim.iq if present.")
    ap.add_argument("--seconds", type=float, default=0.045, help="Generated IQ duration.")
    ap.add_argument("--bursts", type=int, default=1, help="Generated IQ burst count.")
    ap.add_argument("--snr", type=float, default=24.0)
    ap.add_argument("--no-noise", action="store_true")
    ap.add_argument("--max-samples", type=int, default=0, help="0 means all samples in IQ file.")
    ap.add_argument("--csv", type=Path, default=SIM_DATA / "rtl_plot.csv")
    ap.add_argument("--png", type=Path, default=SIM_DATA / "rtl_demod_plots.png")
    ap.add_argument("--html", type=Path, default=SIM_DATA / "rtl_demod_plots.html")
    ap.add_argument("--png-output", action="store_true", help="Use matplotlib and write PNG instead of dependency-free HTML.")
    ap.add_argument("--generate-iq", action="store_true", help="Generate a new IQ file with iqgen.py; requires numpy.")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--skip-rtl", action="store_true", help="Only plot an existing CSV.")
    args = ap.parse_args()

    SIM_DATA.mkdir(parents=True, exist_ok=True)
    default_iq = SIM_DATA / "sim.iq"
    iq = args.iq or (default_iq if default_iq.exists() else SIM_DATA / "sim_plot.iq")
    iq = iq.resolve()
    csv_path = args.csv.resolve()
    png_path = args.png.resolve()
    trace = (SIM_DATA / "rtl_plot_model.trace.txt").resolve()
    expect = (SIM_DATA / "rtl_plot.expect.txt").resolve()

    if args.generate_iq and not args.skip_rtl:
        generate_iq(iq, args.seconds, args.bursts, args.snr, args.no_noise)
    if not iq.exists() and not args.skip_rtl:
        raise SystemExit(f"ERROR: IQ file does not exist: {iq}")

    if not args.skip_rtl:
        cfg = make_expect(iq, trace, expect)
        run_rtl(iq, csv_path, cfg, args.max_samples)

    if args.png_output:
        plot_csv(csv_path, png_path, args.show)
    else:
        plot_html(csv_path, args.html.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
