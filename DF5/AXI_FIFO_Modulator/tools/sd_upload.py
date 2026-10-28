#!/usr/bin/env python3
"""
sd_upload.py -- write a file onto the board's microSD card over JTAG.

The running firmware (vitis/src/app/sd_iq.c) serves a mailbox sd_iq_box in RAM:
this script finds it in the ELF (mb-nm), cuts the file into 4 KB chunks and
drives xsct: CREATE <name>, WRITE chunk by chunk, CLOSE. The firmware writes
through FatFs and, once the file is closed, starts a new capture from it.

    python sd_upload.py [file] [--name SIM.IQ]

Defaults: vivado/sources/sim_data/sim.iq -> SIM.IQ. Needs the board running
(scripts/run_board.tcl) with a FAT-formatted card, and xsct (Vitis) installed.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ELF = os.path.join(ROOT, "vitis", "elf", "df5_app.elf")
VITIS = os.environ.get("XILINX_VITIS", r"C:\AMDDesignTools\2025.2.1\Vitis")
CHUNK = 4096
BOX_FIELDS = 20                      # magic, cmd, len, status, total; then buf
MAGIC = 0x55504C44


def symbol(name):
    nm = os.path.join(VITIS, "gnu", "microblaze", "nt", "bin", "mb-nm.exe")
    out = subprocess.run([nm, ELF], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3 and f[2] == name:
            return int(f[0], 16)
    sys.exit(f"ERROR: {name} not found in {ELF}")


def tcl_path(p):
    return p.replace("\\", "/")


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", default=os.path.join(ROOT, "vivado", "sources", "sim_data", "sim.iq"))
    ap.add_argument("--name", default="SIM.IQ", help="8.3 file name on the card")
    args = ap.parse_args()

    data = open(args.file, "rb").read()
    box = symbol("sd_iq_box")
    buf = box + BOX_FIELDS
    n_chunks = (len(data) + CHUNK - 1) // CHUNK
    print(f"{args.file}: {len(data)} bytes -> {args.name}, {n_chunks} chunks, mailbox 0x{box:08X}")

    with tempfile.TemporaryDirectory() as tmp:
        name_words = (args.name.encode("ascii") + b"\0").ljust(16, b"\0")
        lines = [
            "connect",
            'targets -set -nocase -filter {name =~ "MicroBlaze #0*"}',
            f"set box 0x{box:08X}",
            "proc wait_cmd {box} {",
            "  for {set t 0} {$t < 20000} {incr t} {",
            "    if {[mrd -value [expr {$box + 4}] 1] == 0} { return [mrd -value [expr {$box + 12}] 1] }",
            "    after 1",
            "  }",
            '  error "firmware does not answer"',
            "}",
            "proc cmd {box c len} {",
            "  stop",
            "  mwr [expr {$box + 8}] $len",
            "  mwr [expr {$box + 4}] $c",
            "  con",
            "  set st [wait_cmd $box]",
            '  if {$st != 0} { error "command $c: FatFs error $st" }',
            "}",
            f'if {{[mrd -value $box 1] != {MAGIC}}} {{ error "mailbox not ready: firmware without SD upload or card not mounted" }}',
            "stop",
        ]
        for k in range(0, 16, 4):
            lines.append(f"mwr 0x{buf + k:08X} 0x{struct.unpack_from('<I', name_words, k)[0]:08X}")
        lines += ["con", "cmd $box 1 0", 'puts "CREATE ok"']
        for i in range(n_chunks):
            part = data[i * CHUNK:(i + 1) * CHUNK]
            path = os.path.join(tmp, f"c{i:04d}.bin")
            open(path, "wb").write(part)
            lines += ["stop", f"dow -data {{{tcl_path(path)}}} 0x{buf:08X}", "con",
                      f"cmd $box 2 {len(part)}"]
            if i % 32 == 31 or i == n_chunks - 1:
                lines.append(f'puts "chunk {i + 1}/{n_chunks}"')
        lines += ["cmd $box 3 0", 'puts "TOTAL [mrd -value [expr {$box + 16}] 1]"', 'puts "UPLOAD OK"']
        script = os.path.join(tmp, "upload.tcl")
        open(script, "w").write("\n".join(lines) + "\n")

        xsct = os.path.join(VITIS, "bin", "xsct.bat")
        p = subprocess.run(["cmd", "/c", xsct, script], capture_output=True, text=True)
        out = p.stdout + p.stderr
        for line in out.splitlines():
            if line.startswith(("CREATE", "chunk", "TOTAL", "UPLOAD")) or "error" in line.lower():
                print(line)
        ok = "UPLOAD OK" in out
        total = next((int(l.split()[1]) for l in out.splitlines() if l.startswith("TOTAL")), -1)
        if ok and total != len(data):
            print(f"ERROR: the card got {total} bytes, the file has {len(data)}")
            ok = False
        print("RESULT:", "PASS" if ok else "FAIL")
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
