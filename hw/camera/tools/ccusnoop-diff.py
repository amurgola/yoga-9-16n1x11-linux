#!/usr/bin/env python3
"""Diff two register dumps in ccusnoop format (last DUMP of each). usage: ccusnoop-diff.py windows.log linux.log"""
import re,sys
def last(log):
    D=[];cur=None
    for l in open(log,errors='replace'):
        l=l.rstrip('\r\n')
        if l.startswith('=== DUMP'): cur={}; D.append(cur); continue
        m=re.match(r'\s+(\w+)\+([0-9a-f]+):\s+(.*)',l)
        if m and cur is not None:
            for i,v in enumerate(m[3].split()): cur[(m[1],int(m[2],16)+4*i)]=int(v,16)
    return [d for d in D if d][-1]
a,b=last(sys.argv[1]),last(sys.argv[2])
blocks=sorted({k[0] for k in a}|{k[0] for k in b})
for blk in blocks:
    ka={o:v for (bb,o),v in a.items() if bb==blk}; kb={o:v for (bb,o),v in b.items() if bb==blk}
    d=[(o,ka.get(o,0),kb.get(o,0)) for o in sorted(set(ka)|set(kb)) if ka.get(o,0)!=kb.get(o,0)]
    tag='' if ka and kb else ('  (windows only)' if ka else '  (linux only)')
    print(f"## {blk}: {len(d)} differ{tag}")
    for o,w,l in d: print(f"  {blk}+{o:x}: windows {w:08x}  linux {l:08x}")
