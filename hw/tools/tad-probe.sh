#!/bin/bash
# Awake probe of the EC wake timer (ACPI000E): does it accept a value, count
# down, and flag expiry?  No suspend involved.  Usage: sudo tad-probe.sh
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
T=/sys/devices/platform/ACPI000E:00
[[ -e /proc/acpi/call ]] || modprobe acpi_call 2>/dev/null || insmod "${ACPI_CALL_KO:-acpi_call.ko}" || { echo "acpi_call missing"; exit 1; }
call() { printf '%s' "$1" > /proc/acpi/call; tr -d '\0' < /proc/acpi/call; echo; }
raw() { echo "    reply bytes @20A: $(call '\_SB.RECM 0xFE0B020A 8')"; }

echo "on AC: $(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)"
for id in 0 1; do
  echo "timer $id (0=AC 1=DC)"
  echo "  before: _TIV=$(call "\\_SB.RTC._TIV $id")  _TIP=$(call "\\_SB.RTC._TIP $id")  _GWS=$(call "\\_SB.RTC._GWS $id")"; raw
  echo "  _CWS -> $(call "\\_SB.RTC._CWS $id")"
  echo "  _STP 60 s -> $(call "\\_SB.RTC._STP $id 0x3c")"; raw
  echo "  _STV 40 s -> $(call "\\_SB.RTC._STV $id 0x28")"; raw
  echo "  _TIV now -> $(call "\\_SB.RTC._TIV $id")"; raw
done
for i in $(seq 1 12); do
  sleep 5
  echo "t+$((i*5))s  AC: TIV=$(call '\_SB.RTC._TIV 0') GWS=$(call '\_SB.RTC._GWS 0')   DC: TIV=$(call '\_SB.RTC._TIV 1') GWS=$(call '\_SB.RTC._GWS 1')"
done
echo "sysfs: ac_alarm=$(cat $T/ac_alarm) dc_alarm=$(cat $T/dc_alarm) ac_status=$(cat $T/ac_status) dc_status=$(cat $T/dc_status)"
call '\_SB.RTC._CWS 0' >/dev/null; call '\_SB.RTC._CWS 1' >/dev/null
call '\_SB.RTC._STV 0 0xFFFFFFFF' >/dev/null; call '\_SB.RTC._STV 1 0xFFFFFFFF' >/dev/null
echo "timers disarmed"
