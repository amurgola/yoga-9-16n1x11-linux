#!/bin/bash
# First test of the 83N7 IR camera (VD55G0 + LM3644 IR LEDs). Run with sudo from a desktop session.
# Loads this directory's module with ir=1 (the installed one has the IR camera off), grabs frames,
# writes $OUT/ir.png, then puts the installed module and the desktop's camera service back.
#   sudo ./ir-test.sh            Windows' MIPI rate (1500 Mbps)
#   sudo MBPS=1086 ./ir-test.sh  the rate the Surface's receiver tables were tuned at
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); OUT=${OUT:-/tmp/n1xcam}; N=${N:-40}; MBPS=${MBPS:-1500}
U=${SUDO_USER:-$USER}; UID_=$(id -u "$U")
asuser() { sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus "$@"; }
mkdir -p "$OUT"; chown "$U" "$OUT"
modinfo "$HERE/n1x_yoga_cam.ko" | grep -q "vermagic:.*$(uname -r) " || { echo "module not built for this kernel (make)"; exit 1; }
grep -q '^n1x_ccu_boot ' /proc/modules || modprobe n1x_ccu_boot || { echo "CCU boot module missing"; exit 1; }

restore() {
  echo "== restoring the installed camera driver"
  rmmod n1x_yoga_cam 2>/dev/null
  modprobe n1x_yoga_cam
  asuser systemctl --user start wireplumber 2>/dev/null
}
trap restore EXIT

echo "== stopping the desktop's camera/audio session manager for the test (sound returns afterwards)"
asuser systemctl --user stop wireplumber 2>/dev/null
sleep 1
rmmod n1x_yoga_cam 2>/dev/null
grep -q '^n1x_yoga_cam ' /proc/modules && { echo "camera module is still in use (close any app using the camera)"; exit 1; }
t0=$(date '+%F %T')
OPTS=$(sed -n 's/^options n1x_yoga_cam //p' /etc/modprobe.d/n1x-yoga-cam.conf 2>/dev/null | head -1)   # same options as the installed driver (libcamera matches on them)
insmod "$HERE/n1x_yoga_cam.ko" $OPTS ir=1 ir_mbps=$MBPS ${EXTRA:-} || { echo "insmod failed"; dmesg | tail -5; exit 1; }
sleep 1
dev=$(for d in /dev/video*; do v4l2-ctl -d "$d" --info 2>/dev/null | grep -q 'IR Camera' && echo "$d" && break; done)
[[ -n ${dev:-} ]] || { echo "no IR video node"; journalctl -k --since "$t0" --no-pager | grep n1x-yoga | tail; exit 1; }
echo "IR device: $dev"; v4l2-ctl -d "$dev" --get-fmt-video | grep -E 'Width|Pixel'
rm -f "$OUT"/ir*.raw "$OUT"/ir*.png
grab() {  # name, then v4l2 controls
  local name=$1; shift
  for c in "$@"; do v4l2-ctl -d "$dev" -c "$c" 2>&1 | grep -v '^$'; done
  timeout 25 v4l2-ctl -d "$dev" --stream-mmap=3 --stream-count="$N" --stream-to="$OUT/ir-$name.raw" 2>&1 | tr "\r" "\n" | grep -o "[0-9.]* fps" | tail -1
  [[ -s "$OUT/ir-$name.raw" ]] || { echo "$name: NO FRAMES"; return; }
  tail -c $((640*480)) "$OUT/ir-$name.raw" > "$OUT/ir-$name-last.raw"
  python3 -I -c 'import sys;b=open(sys.argv[1],"rb").read();print("%s: %d frames, last: min %d max %d mean %.1f"%(sys.argv[2],int(sys.argv[3])//len(b),min(b),max(b),sum(b)/len(b)))' "$OUT/ir-$name-last.raw" "$name" "$(stat -c %s "$OUT/ir-$name.raw")"
  ffmpeg -loglevel error -y -f rawvideo -pix_fmt gray -s 640x480 -i "$OUT/ir-$name-last.raw" "$OUT/ir-$name.png"
}
N=45
grab final
cp "$OUT/ir-final.png" "$OUT/ir.png" 2>/dev/null
echo "== libcamera with both cameras present"
sleep 2; asuser timeout 20 cam -l 2>&1 | grep -E 'Adding camera|^[0-9]+:|Available|ERROR' | sed 's/^.*camera_manager.cpp:[0-9]* //' | head -8
asuser timeout 20 cam -c1 --capture=10 2>&1 | grep -E 'fps' | tail -1
echo "== kernel log"
journalctl -k --since "$t0" --no-pager | grep -E 'n1x-yoga-cam|n1x_yoga' | sed 's/^.*kernel: //' | cut -c1-200 | tail -25
chown "$U" "$OUT"/ir* 2>/dev/null
echo "images: $OUT/ir-*.png"
