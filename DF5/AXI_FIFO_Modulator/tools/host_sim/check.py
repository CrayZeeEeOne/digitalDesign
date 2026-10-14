#!/usr/bin/env python3
"""
check.py -- compare rendered viewer screens with golden.md5.

    check.py OUT_DIR            compare OUT_DIR/viewNN.ppm with golden.md5
    check.py OUT_DIR -update    write golden.md5 from OUT_DIR

A mismatch means a screen looks different from the stored reference: expected
after an intended visual change (then run with -update), a bug otherwise.
Also writes OUT_DIR/montage.png (all screens, 4x3) if Pillow is installed.
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "golden.md5")
VIEWS = 12


def digests(out_dir):
    res = {}
    for i in range(VIEWS):
        name = "view%02d.ppm" % i
        with open(os.path.join(out_dir, name), "rb") as f:
            res[name] = hashlib.md5(f.read()).hexdigest()
    return res


def montage(out_dir):
    try:
        from PIL import Image
    except ImportError:
        return
    ims = [Image.open(os.path.join(out_dir, "view%02d.ppm" % i)) for i in range(VIEWS)]
    w, h = ims[0].size
    sheet = Image.new("RGB", (4 * (w + 4), 3 * (h + 4)), (40, 40, 40))
    for i, im in enumerate(ims):
        sheet.paste(im, ((i % 4) * (w + 4), (i // 4) * (h + 4)))
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

    bad = [n for n in sorted(cur) if golden.get(n) != cur[n]]
    for n in sorted(cur):
        print("%s  %s" % ("DIFF" if n in bad else "same", n))
    print("%d of %d screens differ from golden.md5" % (len(bad), len(cur)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
