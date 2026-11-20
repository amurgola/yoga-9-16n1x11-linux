#!/bin/bash
# sudo config/touchpad/install-touchpad-haptic.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
install -Dm755 "$here/touchpad-haptic.py"            /usr/local/bin/touchpad-haptic
install -Dm644 "$here/72-n1x-touchpad-haptic.rules"  /etc/udev/rules.d/72-n1x-touchpad-haptic.rules
install -Dm755 "$here/touchpad-haptic.sleep"         /usr/lib/systemd/system-sleep/touchpad-haptic
udevadm control --reload
udevadm trigger --action=add --subsystem-match=hidraw
echo "installed; current run:"; /usr/local/bin/touchpad-haptic 30
