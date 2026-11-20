#!/usr/bin/env python3
"""Read-only dump of the SoC GPIO controller page (\\_SB.GIO0, 0x1002D000) in the
same format ledsnoop writes on Windows:  '  gpio+OFF: w0 .. w7' (all-zero lines skipped).
Usage: sudo gpio-dump.py OUTFILE"""
import mmap, os, struct, sys
BASE, SIZE = 0x1002D000, 0x1000
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, SIZE, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
words = [struct.unpack_from("<I", m, o)[0] for o in range(0, SIZE, 4)]
with open(sys.argv[1], "w") as f:
    for i in range(0, len(words), 8):
        if any(words[i:i+8]):
            f.write("  gpio+%03x: %s\n" % (i * 4, " ".join("%08x" % w for w in words[i:i+8])))
print("wrote", sys.argv[1])
