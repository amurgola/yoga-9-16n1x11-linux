#!/bin/bash
# Lenovo 83N7: does the EC thermal mode (GameZone "smart fan mode", EC RAM 0xFE0B034D) move the
# SoC power limits (PL1/PL2 at 0x1C238160/164)?  Uses the firmware's own method \_SB.GZFD.WMAA
# (0x2D = get, 0x2C = set) through acpi_call, and restores the original mode at the end.
#   sudo hw/tools/thermal-mode-probe.sh            # read only: current mode + limits
#   sudo hw/tools/thermal-mode-probe.sh 3 1 2      # try these modes in order, 6 s each, then restore
#   sudo hw/tools/thermal-mode-probe.sh --keep 3   # set mode 3 and leave it
# Lenovo's usual values: 1 = quiet, 2 = balanced, 3 = performance.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
KO=${ACPI_CALL_KO:-acpi_call.ko}   # github.com/nix-community/acpi_call, built for the running kernel
[[ -e /proc/acpi/call ]] || insmod "$KO" || modprobe acpi_call
call() { printf '%s' "$1" > /proc/acpi/call; tr -d '\0' < /proc/acpi/call; echo; }
limits() { python3 -I - <<'EOF'
import ctypes, mmap, os
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x1C238000)
w = lambda o: ctypes.c_uint32.from_buffer_copy(mm, o).value
print("PL1=%.1fW PL2=%.1fW x168=%.1fW SPL=%d/%d/%d/%dW  SoC now=%.1fW" % (
    w(0x160)/1e3, w(0x164)/1e3, w(0x168)/1e3, w(0x170)//1000, w(0x174)//1000, w(0x178)//1000, w(0x17C)//1000, w(0x800)/1e3))
EOF
}
state() { echo "  mode(WMAA get)=$(call '\_SB.GZFD.WMAA 0 0x2D 0')  EC[034D]=$(call '\_SB.RECM 0xFE0B034D 1')"
          echo "  EC[0340..034F]=$(call '\_SB.RECM 0xFE0B0340 16')"; echo "  $(limits)"; }
keep=0; [[ ${1:-} == --keep ]] && { keep=1; shift; }
echo "== now"; state
orig=$(call '\_SB.GZFD.WMAA 0 0x2D 0')
for m in "$@"; do
  [[ $m =~ ^[0-9]+$ || $m =~ ^0x[0-9A-Fa-f]+$ ]] || { echo "bad mode $m" >&2; exit 1; }
  echo "== set mode $m -> $(call "\\_SB.GZFD.WMAA 0 0x2C $m")"
  for s in 1 3 6; do sleep $((s==1?1:(s==3?2:3))); echo " +${s}s"; state; done
done
if (($# > 0 && keep == 0)); then
  echo "== restore mode $orig -> $(call "\\_SB.GZFD.WMAA 0 0x2C $orig")"; sleep 2; state
fi
