#!/usr/bin/env python3
"""
check.py -- compare rendered viewer screens with golden.md5.

    check.py OUT_DIR            compare OUT_DIR/view*.ppm with golden.md5
    check.py OUT_DIR -update    write golden.md5 from OUT_DIR

A mismatch means a screen looks different from the stored reference: expected
after an intended visual change (then run with -update), a bug otherwise.
Also writes OUT_DIR/montage.png (all screens) if Pillow is installed.
"""
import glob
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "golden.md5")
COLS = 3


def screens(out_dir):
    return sorted(glob.glob(os.path.join(out_dir, "view*.ppm")))


def digests(out_dir):
    res = {}
    for path in screens(out_dir):
        with open(path, "rb") as f:
            res[os.path.basename(path)] = hashlib.md5(f.read()).hexdigest()
    return res


def montage(out_dir):
    try:
        from PIL import Image
    except ImportError:
        return
    ims = [Image.open(p) for p in screens(out_dir)]
    if not ims:
        return
    w, h = ims[0].size
    rows = (len(ims) + COLS - 1) // COLS
    sheet = Image.new("RGB", (COLS * (w + 4), rows * (h + 4)), (40, 40, 40))
    for i, im in enumerate(ims):
        sheet.paste(im, ((i % COLS) * (w + 4), (i // COLS) * (h + 4)))
    sheet.save(os.path.join(out_dir, "montage.png"))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out_dir = sys.argv[1]
    update = len(sys.argv) > 2 and sys.argv[2] == "-update"
    cur = digests(out_dir)
    montage(out_dir)

    if update:
        with open(GOLDEN, "w", newline="\n") as f:
            for name in sorted(cur):
                f.write("%s  %s\n" % (cur[name], name))
        print("golden.md5 updated (%d screens)" % len(cur))
        return 0

    if not os.path.exists(GOLDEN):
        print("no golden.md5 yet: run with -update")
        return 1
    golden = {}
    with open(GOLDEN) as f:
        for line in f:
            digest, name = line.split()
            golden[name] = digest

    bad = [n for n in sorted(set(cur) | set(golden)) if golden.get(n) != cur.get(n)]
    for n in sorted(set(cur) | set(golden)):
        print("%s  %s" % ("DIFF" if n in bad else "same", n))
    print("%d of %d screens differ from golden.md5" % (len(bad), len(set(cur) | set(golden))))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
