#!/bin/bash
# Lenovo 83N7: talk to the EC through the firmware's own ACPI helpers (SSDT "LfcECCom":
# \_SB.RECM/WECM over the FF-A EC-RAM service), using the acpi_call module.
#   sudo hw/tools/lenovo-ec.sh read  0xFE0B0200 16      # read bytes
#   sudo hw/tools/lenovo-ec.sh write 0xFE0B0200 0x4D    # write one byte
#   sudo hw/tools/lenovo-ec.sh mute-led on|off          # known: 0x4D / 0x4E on the command register
#   sudo hw/tools/lenovo-ec.sh dump  [out.txt]          # EC RAM 0xFE0B0200..0xFE0B07FF, for diffing
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -e /proc/acpi/call ]] || modprobe acpi_call 2>/dev/null || insmod "${ACPI_CALL_KO:-acpi_call.ko}" || { echo "acpi_call module missing (build ~/src/acpi_call)" >&2; exit 1; }
call() { printf '%s' "$1" > /proc/acpi/call; tr -d '\0' < /proc/acpi/call; echo; }
case "${1:-}" in
  read)   call "\\_SB.RECM $2 $3" ;;                      # returns {status, buffer}
  write)  call "\\_SB.WECM $2 1 $3" ;;                     # returns status (0 = ok)
  mute-led) v=1; [[ $2 == off ]] && v=2; call "\\_SB.WMIU.WMSK 0 2 b0$v" ;;      # the firmware's own "F4 MuteLED" method (0 = ok)
  dump)   out=${2:-/tmp/ec-ram-$(date +%H%M%S).txt}; : > "$out"
          for ((a=0xFE0B0200; a<0xFE0B0800; a+=16)); do printf '%08x: ' $a >> "$out"; call "\\_SB.RECM $(printf '0x%X' $a) 16" | tr -d '\n' >> "$out"; echo >> "$out"; done
          echo "wrote $out" ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
