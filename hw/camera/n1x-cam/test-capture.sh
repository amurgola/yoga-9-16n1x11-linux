#!/bin/bash
# First-frame test for the 83N7 front camera port. Run as root, on a kernel with cma=96M.
# Steps: load deps, boot the CCU (n1x_ccu_boot go=1, once per boot), load n1x_yoga_cam,
# grab N frames with v4l2-ctl, convert the last one to PNG with ffmpeg (bayer_grbg16le).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
N=${1:-5}; OUT=${2:-/tmp/n1xcam}; HERE=$(cd "$(dirname "$0")" && pwd)
PACKED=${PACKED:-0}; BLIND=${BLIND:-0}   # BLIND=1: hand out buffers at every SOF regardless of the write counter (debug)   # PACKED=1: Windows' MTK packed RAW10 (4800-byte lines) instead of unpacked 16-bit
mkdir -p "$OUT"
cma=$(awk '/CmaTotal/{print $2}' /proc/meminfo); cmafree=$(awk '/CmaFree/{print $2}' /proc/meminfo)
echo "CMA: ${cma} kB total, ${cmafree} kB free (3 buffers need ~54000 kB)"
(( cmafree >= 56000 )) || { echo "not enough free CMA: other drivers (NVIDIA GSP) already hold most of it; raise cma= on the kernel command line (cma=256M) and reboot" >&2; exit 1; }
modprobe videobuf2_dma_contig; modprobe videobuf2_v4l2; modprobe v4l2_fwnode 2>/dev/null || true
grep -q '^n1x_cam_power ' /proc/modules && { echo "unload n1x_cam_power first (it shares the HFRP mailbox)" >&2; exit 1; }
if ! grep -q '^n1x_ccu_boot ' /proc/modules; then
  echo "booting the CCU firmware (n1x_ccu_boot go=1)..."; insmod "$HERE/../n1x-ccu-boot/n1x_ccu_boot.ko" go=1
  sleep 1; dmesg | grep -iE 'n1x_ccu_boot|ccu:' | tail -6
fi
grep -q '^n1x_yoga_cam ' /proc/modules && rmmod n1x_yoga_cam
insmod "$HERE/n1x_yoga_cam.ko" packed=$PACKED blind=$BLIND
sleep 1; dmesg | grep -E 'n1x-yoga-cam|n1x_yoga' | tail -5
dev=$(for d in /dev/video*; do v4l2-ctl -d "$d" --info 2>/dev/null | grep -q 'Lenovo Yoga' && echo "$d" && break; done)
[[ -n ${dev:-} ]] || { echo "no video node from the driver" >&2; exit 1; }
echo "device: $dev"; v4l2-ctl -d "$dev" --get-fmt-video
rm -f "$OUT/frames.raw"
if [[ ${DUMP:-0} == 1 ]]; then
  # DUMP=1: stream for a few seconds and dump every camera block while powered, then diff with Windows
  timeout 12 v4l2-ctl -d "$dev" --stream-mmap=3 --stream-count=1000 --stream-to=/dev/null >/dev/null 2>&1 &
  sleep 4; python3 -I "$HERE/../tools/linux-camdump.py" "$OUT/linux-dump.log"; wait || true
  python3 -I "$HERE/../tools/ccusnoop-diff.py" "${WINLOG:?set WINLOG to a ccusnoop.log recorded on Windows}" "$OUT/linux-dump.log" | tee "$OUT/diff-vs-windows.txt" | head -80
  echo "(full diff: $OUT/diff-vs-windows.txt)"; exit 0
fi
timeout 30 v4l2-ctl -d "$dev" --stream-mmap=3 --stream-count="$N" --stream-to="$OUT/frames.raw" --verbose 2>&1 | tail -8 || true
dmesg | grep -E 'n1x-yoga-cam|n1x_yoga|camsv|diag:' | tail -12
if [[ -s "$OUT/frames.raw" ]]; then
  if (( PACKED )); then fs=$((3840*2400*5/4)); else fs=$((3840*2400*2)); fi
  sz=$(stat -c %s "$OUT/frames.raw"); echo "got $((sz/fs)) frame(s) of $fs bytes"
  tail -c $fs "$OUT/frames.raw" > "$OUT/last.raw"
  if (( PACKED )); then
    python3 -I - "$OUT/last.raw" <<'PY'
import sys, numpy as np
b=np.fromfile(sys.argv[1],dtype=np.uint8); nz=np.count_nonzero(b)
print("packed frame: %d bytes, %.1f%% nonzero, first 16: %s" % (b.size, 100*nz/b.size, ' '.join('%02x'%x for x in b[:16])))
# MTK packed RAW10: 4 pixels in 5 bytes, little-endian bit stream
w=b[:b.size//5*5].reshape(-1,5).astype(np.uint16)
p0=(w[:,0]|(w[:,1]<<8))&0x3ff; p1=((w[:,1]>>2)|(w[:,2]<<6))&0x3ff; p2=((w[:,2]>>4)|(w[:,3]<<4))&0x3ff; p3=((w[:,3]>>6)|(w[:,4]<<2))&0x3ff
px=np.stack([p0,p1,p2,p3],1).ravel()[:3840*2400]
print("unpacked stats: min %d max %d mean %.1f" % (px.min(),px.max(),px.mean()))
px.astype('<u2').tofile(sys.argv[1]+".u16"); print("wrote", sys.argv[1]+".u16 (3840x2400 16-bit BGGR)")
PY
    ffmpeg -loglevel error -y -f rawvideo -pix_fmt bayer_bggr16le -s 3840x2400 -i "$OUT/last.raw.u16" -vf "scale=1920:1200" "$OUT/last.png" && echo "image: $OUT/last.png"
    exit 0
  fi
  # 10-bit in 16-bit words, BGGR. last.png = true exposure (10->16 bit), last_stretch.png = auto-levelled
  python3 -I - "$OUT/last.raw" "$OUT" <<'PY'
import sys, numpy as np
a=np.fromfile(sys.argv[1],dtype='<u2'); nz=np.count_nonzero(a)
print("pixel stats: %.1f%% nonzero, min %d max %d mean %.1f (10-bit: expect 0..1023; all zero = DMA wrote nothing)"%(100*nz/a.size,a.min(),a.max(),a.mean()))
rows=a.reshape(2400,3840); nzr=np.count_nonzero(rows.any(1)); print("lines with data: %d of 2400"%nzr)
(rows.astype(np.uint16)<<6).astype('<u2').tofile(sys.argv[2]+"/last16.raw")
lo,hi=np.percentile(rows,[0.5,99.8]); s=np.clip((rows.astype(np.float32)-lo)/max(hi-lo,1),0,1); (s*65535).astype('<u2').tofile(sys.argv[2]+"/last16_stretch.raw")
PY
  for v in last16 last16_stretch; do ffmpeg -loglevel error -y -f rawvideo -pix_fmt bayer_bggr16le -s 3840x2400 -i "$OUT/$v.raw" -vf "scale=1920:1200" "$OUT/${v/last16/last}.png"; done
  echo "images: $OUT/last.png (true exposure), $OUT/last_stretch.png (auto-levelled)"
else
  echo "no frames captured"
fi
