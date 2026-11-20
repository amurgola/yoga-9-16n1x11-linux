#!/bin/bash
# Timer wake from sleep for the Lenovo 83N7.  sudo ./install.sh [period-seconds, default 7200]
# The module is rebuilt by DKMS at kernel updates.  period 0 = load the module but never wake by itself.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
period=${1:-7200}
krel=$(uname -r)
"$here/../dkms/install.sh" | tail -2    # module built and installed by DKMS
echo n1x_wake_timer > /etc/modules-load.d/n1x-wake-timer.conf
echo "options n1x_wake_timer period=$period" > /etc/modprobe.d/n1x-wake-timer.conf
install -Dm755 "$here/n1x-wake-timer.sleep" /usr/lib/systemd/system-sleep/n1x-wake-timer
rmmod n1x_wake_timer 2>/dev/null || true
modprobe n1x_wake_timer
echo "loaded: period=$(cat /sys/module/n1x_wake_timer/parameters/period) s; log: /var/log/n1x-sleep.log"
