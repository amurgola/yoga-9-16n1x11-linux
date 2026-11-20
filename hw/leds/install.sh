#!/bin/bash
# F4 microphone-mute light for the Lenovo 83N7.
#   sudo ./install.sh root   kernel module (DKMS) + udev rule
#   ./install.sh             user service that follows the microphone's mute state
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [[ ${1:-} == root ]]; then
  [[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
  krel=$(uname -r)
  "$here/../dkms/install.sh" | tail -2    # module built and installed by DKMS
  echo n1x_yoga_leds > /etc/modules-load.d/n1x-yoga-leds.conf
  cat > /etc/udev/rules.d/72-n1x-yoga-leds.rules <<'RULE'
# let the desktop user drive the F4 microphone-mute light
ACTION=="add", SUBSYSTEM=="leds", KERNEL=="platform::micmute", RUN+="/usr/bin/chmod 0666 /sys/class/leds/platform::micmute/brightness"
RULE
  udevadm control --reload
  rmmod n1x_yoga_leds 2>/dev/null || true
  modprobe n1x_yoga_leds
  sleep 0.5; ls -l /sys/class/leds/platform::micmute/brightness
  exit 0
fi
[[ $EUID -ne 0 ]] || { echo "run the user part without sudo" >&2; exit 1; }
install -Dm755 "$here/n1x-micmute-led" "$HOME/.local/bin/n1x-micmute-led"
install -Dm644 "$here/n1x-micmute-led.service" "$HOME/.config/systemd/user/n1x-micmute-led.service"
systemctl --user daemon-reload
systemctl --user enable --now n1x-micmute-led.service
systemctl --user --no-pager --lines=0 status n1x-micmute-led.service | head -4
