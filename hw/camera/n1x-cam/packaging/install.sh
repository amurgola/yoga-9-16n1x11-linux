#!/bin/bash
# Install the Yoga 83N7 camera driver (modules through DKMS, see hw/dkms/install.sh)
# plus the libcamera / WirePlumber / modprobe integration.
#   sudo hw/camera/n1x-cam/packaging/install.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
TOP=$(cd "$(dirname "$0")/.." && pwd); KREL=$(uname -r); EXTRA=/lib/modules/$KREL/extra
[[ -f /lib/firmware/nvidia/n1x/nvCCU.img ]] || { echo "missing /lib/firmware/nvidia/n1x/nvCCU.img" >&2; exit 1; }
grep -q 'cma=' /proc/cmdline || echo "WARNING: no cma= on the kernel command line; the driver needs cma=256M"
# the kernel modules are built and installed by DKMS (rebuilt automatically at kernel updates)
"$TOP/../../dkms/install.sh" | tail -2
install -Dm644 "$TOP/packaging/modprobe.conf" /etc/modprobe.d/n1x-yoga-cam.conf
install -Dm644 "$TOP/packaging/modules-load.conf" /etc/modules-load.d/n1x-yoga-cam.conf
install -Dm644 "$TOP/libcamera/configuration.yaml" /usr/share/libcamera/configuration.yaml
install -Dm644 "$TOP/libcamera/ipa/simple/ov08x40.yaml" /usr/share/libcamera/ipa/simple/ov08x40.yaml
install -Dm644 "$TOP/wireplumber/50-n1x-yoga-cam.conf" /usr/share/wireplumber/wireplumber.conf.d/50-n1x-yoga-cam.conf
install -Dm644 "$TOP/packaging/environment.conf" /usr/lib/environment.d/50-n1x-yoga-cam.conf
[[ -d /usr/lib/firefox/browser/defaults/preferences ]] && \
  install -m644 "$TOP/packaging/firefox-n1x-yoga-cam.js" /usr/lib/firefox/browser/defaults/preferences/n1x-yoga-cam.js
echo "== reloading the drivers with the installed options (no reboot needed)"
rmmod n1x_yoga_cam 2>/dev/null || true
grep -q '^n1x_ccu_boot ' /proc/modules || modprobe n1x_ccu_boot
modprobe n1x_yoga_cam
sleep 1; dmesg | grep -E 'n1x-yoga-cam|n1x-ccu-boot' | tail -3
echo "== done. Log out and back in (or reboot) so PipeWire/WirePlumber and the environment pick it up."
echo "   Quick checks:  cam -l        (libcamera sees the camera)"
echo "                  cam -c1 --capture=5 --file=/tmp/n1xcam/cam-#.ppm   (libcamera frames through the software ISP)"
