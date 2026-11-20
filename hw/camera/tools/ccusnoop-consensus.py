#!/usr/bin/env python3
"""Merge two ccusnoop mailbox captures into one replay table (Surface struct ccucmd format).
usage: ccusnoop-consensus.py capture1.log capture2.log surface_ccu_replay.h out.h"""
import re,sys
a,b,surf,out=sys.argv[1:5]
def parse(log):
    O=[]
    for l in open(log,errors='replace'):
        m=re.match(r'mb0 w=(\d+) ft=(\d+) cmd=0x([0-9a-f]+) len=(\d+) st=0x([0-9a-f]+) pl:(.*)',l.strip())
        if not m: continue
        w=int(m[1])
        if w<1 or w>500: continue
        ln=int(m[4]); O.append((w,int(m[2]),int(m[3],16),ln,[int(x,16) for x in m[6].split()][:ln]))
    return O
A,B=parse(a),parse(b)
S=[]  # normalised below to (w, ft, cmd, len, pl) like the captures
for m in re.finditer(r'\{\s*(\d+),\s*(0x[0-9a-f]+),\s*(\d+),\s*\{([^}]*)\}\s*\}',open(surf).read()):
    S.append((int(m[1]),int(m[2],16),int(m[3]),[int(x,16) for x in re.findall(r'0x[0-9a-f]{2}',m[4])][:int(m[3])]))
S=[(0,)+e for e in S]
fmt=lambda pl:' '.join('%02x'%x for x in pl)
print(f"capture1: {len(A)} msgs  capture2: {len(B)} msgs  surface: {len(S)}")
import difflib
good=lambda cmd,pl:(cmd!=0xa0) or (len(pl)>=4 and pl[2]==0xa1 and pl[3]==0x12)
# alignment key: feature, command, and for 0xa0 the target register (when the read was not torn)
def key(e):
    ft,cmd,pl=e[1],e[2],e[4]
    if cmd==0xa0 and good(cmd,pl): return (ft,cmd,pl[0]|pl[1]<<8)
    if cmd==0xa0: return (ft,cmd,'torn')
    return (ft,cmd)
def align(X,Y):
    """map index in X -> index in Y using difflib on keys; torn 0xa0 entries match any 0xa0"""
    kx=[key(e) for e in X]; ky=[key(e) for e in Y]
    # treat torn as wildcard by substituting the opposite side's key where a lone 0xa0 sits between matches
    sm=difflib.SequenceMatcher(None,kx,ky,autojunk=False); m={}
    for tag,i1,i2,j1,j2 in sm.get_opcodes():
        if tag=='equal':
            for k in range(i2-i1): m[i1+k]=j1+k
        elif tag=='replace' and (i2-i1)==(j2-j1):
            for k in range(i2-i1):
                if X[i1+k][1:3]==Y[j1+k][1:3]: m[i1+k]=j1+k
    return m
mB=align(A,B); mS=align(A,S)
cons=[]; print("\n#   ft cmd  len  (positions where the captures disagree, c2 missed, or c1 was flagged)")
flagged={0,22,29,35,54,61,63}; unres=0; stats={'agree':0,'c2':0,'missed':0,'surface':0}
for i,x in enumerate(A):
    w,ft,cmd,ln,pl=x; y=B[mB[i]] if i in mB else None; s_=S[mS[i]] if i in mS else None
    same = y is not None and y[4]==pl
    pick,src=pl,'c1'
    if y is None: src='c1 (c2 missed it)'; stats['missed']+=1
    elif same: stats['agree']+=1
    else:
        ga,gb=good(cmd,pl),good(cmd,y[4])
        if gb and not ga: pick,src=y[4],'c2 (c1 torn)'; stats['c2']+=1
        elif ga and not gb: pick,src=pl,'c1 (c2 torn)'; stats['agree']+=1
        elif s_ and s_[4]==y[4]: pick,src=y[4],'c2 (=surface)'; stats['c2']+=1
        elif s_ and s_[4]==pl: pick,src=pl,'c1 (=surface)'; stats['surface']+=1
        else: src='c1 UNRESOLVED'; unres+=1
    if not same or i in flagged:
        print(f"{i:2d}  {ft}  0x{cmd:<3x} {ln:2d}  c1: {fmt(pl)}\n             c2: {fmt(y[4]) if y else '(missed)'}\n             su: {fmt(s_[4]) if s_ else '-'}   -> {src}")
    cons.append((w,ft,cmd,ln,pick,src))
used=set(mB.values())
for j,y in enumerate(B):
    if j not in used: print(f"capture2-only [{j}]: ft{y[1]} 0x{y[2]:x} {fmt(y[4])}")
print(f"\nagree: {stats['agree']}  resolved from c2: {stats['c2']}  c1 kept via surface: {stats['surface']}  c2 missed: {stats['missed']}  unresolved: {unres}")
with open(out,'w') as f:
    f.write('/* SPDX-License-Identifier: GPL-2.0 */\n/*\n * Consensus CCU stream-on sequence for the Lenovo Yoga 9 2-in-1 16N1X11 (83N7) front\n * camera (OV08X40, CSI port 0, 3840x2400), from two Windows ccusnoop captures taken\n * 2026-11-14 (captures/2026-11-14-front and -front-2). Where the two polled captures\n * disagree, the entry whose 0xa0 address field is a seninf register (0x12a1xxxx) wins;\n * anything still in doubt is marked UNRESOLVED. Replayed as-is (Surface struct ccucmd).\n */\nstatic const struct ccucmd ccu_replay_83n7[] = {\n')
    for w,ft,cmd,ln,pl,src in cons:
        f.write('\t{ %d, 0x%x, %d, { %s } },  /* w=%d%s */\n'%(ft,cmd,ln,', '.join('0x%02x'%x for x in pl),w,'' if src=='c1' else ' '+src))
    f.write('};\n')
print("wrote",out)
