#!/usr/bin/env python3
"""Per-pin statistics from ledsnoop logs: for every GPIO word bit, how often it is 1 in
dumps taken with the camera off vs on.  Usage: gpio-bits.py LOG..."""
import re, sys, collections
stats = collections.defaultdict(lambda: [0, 0, 0, 0])   # (off1, offN, on1, onN)
for path in sys.argv[1:]:
    dumps, cur = [], None
    for line in open(path, errors="replace"):
        if line.startswith("=== DUMP"):
            cur = {"gpio": {}, "cam": False}; dumps.append(cur); continue
        if cur is None: continue
        m = re.match(r"\s+(\w+)\+([0-9a-f]+):((?: [0-9a-f]{8})+)", line)
        if not m: continue
        tag, off, words = m.group(1), int(m.group(2), 16), [int(w, 16) for w in m.group(3).split()]
        if tag == "gpio":
            for i, w in enumerate(words): cur["gpio"][off + 4 * i] = w
        elif tag in ("camsv1", "maccsi", "omux1"):
            cur["cam"] = True
    print(path, "dumps:", "".join("1" if d["cam"] else "0" for d in dumps))
    for d in dumps:
        for off in range(0, 0x300, 0x10):
            w = d["gpio"].get(off, 0)
            for b in range(32):
                s = stats[(off, b)]
                if d["cam"]: s[3] += 1; s[2] += (w >> b) & 1
                else: s[1] += 1; s[0] += (w >> b) & 1
names = {0: "DIR", 1: "DOUT", 2: "DIN"}
for (off, b), (o1, on, c1, cn) in sorted(stats.items()):
    if on == 0 or cn == 0: continue
    fo, fc = o1 / on, c1 / cn
    if abs(fo - fc) > 0.15 or (0 < fo < 1) or (0 < fc < 1):
        pin = ((off & 0xff) // 0x10) * 32 + b
        print("%-4s pin %3d (+%03x bit %2d): off %2d/%2d  on %2d/%2d%s" % (names[off >> 8], pin, off, b, o1, on, c1, cn, "   <== follows camera" if abs(fo - fc) > 0.6 else ""))
