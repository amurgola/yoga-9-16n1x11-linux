#!/bin/bash
# Test n1x_wake_timer: (1) does the spare timer fire while awake, (2) does it
# wake the machine from s2idle.  Usage: sudo wake-test.sh [seconds, default 180]
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
SECS=${1:-180}
D=$(dirname "$(readlink -f "$0")")
P=/sys/module/n1x_wake_timer/parameters
rmmod n1x_wake_timer 2>/dev/null
insmod "$D/n1x_wake_timer.ko" || { echo "module did not load:"; dmesg | tail -5; exit 1; }
dmesg | grep n1x_wake_timer | tail -3

echo 5 > $P/seconds; sleep 7
if [ "$(cat $P/fires)" != 1 ]; then
  echo "STEP 1 FAILED: timer did not fire while awake (fires=$(cat $P/fires)); not suspending"
  grep n1x-wake /proc/interrupts; exit 1
fi
echo "step 1 ok: timer fired while awake"

before=$(cat /sys/power/suspend_stats/success)
start=$(date +%s)
echo "$SECS" > $P/seconds
echo "suspending now; do not touch the laptop for $((SECS + 60)) s"
sleep 2
systemctl suspend
while [ "$(cat /sys/power/suspend_stats/success)" = "$before" ]; do sleep 1; done
slept=$(( $(date +%s) - start ))
echo "woke after ${slept} s (timer was ${SECS} s); timer fires total=$(cat $P/fires) (2 = the timer woke it)"
dmesg | grep -E 'n1x_wake_timer|PM: suspend' | tail -4
echo 0 > $P/seconds
