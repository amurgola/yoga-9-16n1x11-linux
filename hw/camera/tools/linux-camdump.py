#!/usr/bin/env python3
"""Dump the camera blocks from Linux (/dev/mem, root) in ccusnoop's format, so they can be
diffed against a Windows dump. ONLY while the camera island is powered and streaming
(the driver's stream is running): a read of an unpowered block stalls the bus.
usage: linux-camdump.py [out.log]   then: ccusnoop-diff.py windows.log out.log"""
import mmap,os,sys,struct
BLOCKS=[  # (name, phys base, length)  -- same names/offsets as ccusnoop
 ('rxanaA',0x12a10000,0x200),('rxanaB',0x12a11000,0x200),('dphy',0x12a12000,0x200),
 ('mactop',0x12a14000,0x100),('maccsi',0x12a15000,0x200),
 *[(f'omux{n}',0x3a100000+n*0x10000,0x200) for n in (0,1,4,6,7,9,11,13)],
 ('camsv1',0x3a510000,0x600),('camsv1dma',0x3a511000,0x400),('camsv1scq',0x3a512000,0x40),
 ('cammain',0x3a000000,0x1000),('camsv0',0x3a500000,0x600),('camsv0dma',0x3a501000,0x400),
]
out=open(sys.argv[1] if len(sys.argv)>1 else '/tmp/n1xcam/linux-dump.log','w')
out.write("=== DUMP #0 (linux) ===\n")
fd=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC)
for name,base,length in BLOCKS:
    # ccusnoop prints offsets relative to the sub-block's own base inside its window; we print
    # name+offset with the same convention: rxanaB/dphy/mactop/maccsi offsets include their
    # window offset (0x1000/0x2000/0x4000/0x5000), omux<n> offsets include n*0x10000,
    # camsv1* offsets include 0x10000/0x11000/0x12000.
    rel={'rxanaB':0x1000,'dphy':0x2000,'mactop':0x4000,'maccsi':0x5000,'camsv1':0x10000,'camsv1dma':0x11000,'camsv1scq':0x12000,'camsv0':0,'camsv0dma':0x1000,'cammain':0}.get(name)
    if rel is None: rel=(base-0x3a100000)
    pg=base&~0xfff; m=mmap.mmap(fd,(base-pg)+length,mmap.MAP_SHARED,mmap.PROT_READ,offset=pg)
    for off in range(0,length,0x20):
        words=[struct.unpack_from('<I',m,(base-pg)+off+4*i)[0] for i in range(8)]
        if any(words): out.write(f"  {name}+{rel+off:x}: "+' '.join('%08x'%w for w in words)+"\n")
    m.close()
out.write("=== END ===\n"); out.close(); print("wrote",out.name)
