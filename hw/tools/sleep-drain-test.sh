#!/bin/bash
# Lenovo 83N7: measure s2idle battery drain over a timed sleep (RTC wake).
# Usage: sudo config/sleep-drain-test.sh [seconds] [--touchpad-wake on|off]
# Run on battery, hands off the machine. One change per run (one test, one question).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
secs=300; tpw=""
while (($#)); do case "$1" in --touchpad-wake) tpw=${2:-}; shift;; [0-9]*) secs=$1;; *) echo "bad arg $1" >&2; exit 1;; esac; shift; done
B=$(ls -d /sys/class/power_supply/BAT* | head -1)
TP=/sys/bus/i2c/devices/i2c-WACF2205:00/power/wakeup
[[ -n $tpw ]] && { case $tpw in on) echo enabled >$TP;; off) echo disabled >$TP;; esac; }
echo 1 >/sys/power/pm_debug_messages
[[ $(cat $B/status) == Discharging ]] || echo "WARNING: not on battery ($(cat $B/status)); numbers will be meaningless"
snap() { for d in /sys/class/wakeup/wakeup*; do echo "$(cat $d/name) $(cat $d/event_count)"; done | sort; }
e0=$(cat $B/energy_now); t0=$(date +%s); snap >/tmp/.drain-wk0
echo "touchpad wakeup=$(cat $TP)  mem_sleep=$(cat /sys/power/mem_sleep)  energy=$((e0/1000)) mWh  sleeping (RTC alarm requested for ${secs}s, but it never wakes the N1X: wake with the power button)..."
# The N1X's RTC alarm neither fires nor, on some boots, accepts a setting; fall back to a plain suspend.
if ! rtcwake -m mem -s "$secs" >/dev/null 2>&1; then
  echo "(rtcwake unavailable; plain suspend)"; sync; echo mem >/sys/power/state
fi
e1=$(cat $B/energy_now); t1=$(date +%s); snap >/tmp/.drain-wk1
dt=$((t1-t0)); dmwh=$(( (e0-e1)/1000 ))
echo "slept ${dt}s, used ${dmwh} mWh  ->  $(awk -v m=$dmwh -v s=$dt 'BEGIN{printf "%.2f W", m/1000/(s/3600)}') average sleep draw"
echo "--- wakeup sources that fired during sleep:"; join /tmp/.drain-wk0 /tmp/.drain-wk1 | awk '$3>$2{print "  "$1, $3-$2}'
echo "--- kernel wake/suspend lines:"; journalctl -k -q --no-pager --since "@$t0" | grep -iE 'PM:|wakeup|wake irq|resume|failed|abort' | grep -vE 'ip-sleep' | sed 's/^.*kernel: /  /' | head -25
