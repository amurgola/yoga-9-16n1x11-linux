#!/bin/bash
# Package the 83N7's out-of-tree kernel modules as one DKMS package, so they are rebuilt
# automatically whenever a kernel (its headers) is installed or upgraded.
#
#   sudo hw/dkms/install.sh            assemble /usr/src/n1x-83n7-<version>, build and install
#   sudo hw/dkms/install.sh --remove   remove the DKMS package (modules stay loaded until reboot)
#
# Modules: n1x_yoga_cam (webcam + IR camera), n1x_ccu_boot (camera co-processor firmware boot),
#          n1x_yoga_leds (F4 microphone-mute key and light), n1x_wake_timer (timer wake from sleep).
# Their configuration (modprobe.d, modules-load.d, udev, firmware) is still installed by each
# module's own install script; this only takes over building and installing the .ko files.
# Rerun after changing any module source: the version is the newest source file's date.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd)
NAME=n1x-83n7

declare -A SRC=(
  [cam]="$TOP/camera/n1x-cam"
  [ccu]="$TOP/camera/n1x-ccu-boot"
  [leds]="$TOP/leds"
  [waketimer]="$TOP/waketimer"
)
declare -A FILES=(
  [cam]="sucam_main.c sucam_hw.c sucam_vd55g0.c sucam_mc.c sucam.h ccu_replay.h golden_mmio.h golden_omux_all.h ir_tables.h ov08x40_win.h"
  [ccu]="n1x_ccu_boot.c"
  [leds]="n1x_yoga_leds.c"
  [waketimer]="n1x_wake_timer.c"
)
declare -A KBUILD=(
  [cam]=$'obj-m := n1x_yoga_cam.o\nn1x_yoga_cam-y := sucam_main.o sucam_hw.o sucam_vd55g0.o sucam_mc.o'
  [ccu]="obj-m := n1x_ccu_boot.o"
  [leds]="obj-m := n1x_yoga_leds.o"
  [waketimer]="obj-m := n1x_wake_timer.o"
)
MODS=(cam:n1x_yoga_cam ccu:n1x_ccu_boot leds:n1x_yoga_leds waketimer:n1x_wake_timer)

remove_all() {
  for v in $(dkms status "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,:]*\).*|\1|p" | sort -u); do
    dkms remove "$NAME/$v" --all || true
    rm -rf "/usr/src/$NAME-$v" "/var/lib/dkms/$NAME"
  done
}
if [[ ${1:-} == --remove ]]; then remove_all; echo "removed"; exit 0; fi

# version = date and time of the newest source file
newest=0
for d in "${!SRC[@]}"; do for f in ${FILES[$d]}; do
  [[ -f ${SRC[$d]}/$f ]] || { echo "missing ${SRC[$d]}/$f" >&2; exit 1; }
  t=$(stat -c %Y "${SRC[$d]}/$f"); (( t > newest )) && newest=$t
done; done
VER=$(date -d "@$newest" +%Y%m%d.%H%M)
DST=/usr/src/$NAME-$VER

remove_all
install -d "$DST"
for d in "${!SRC[@]}"; do
  install -d "$DST/$d"
  for f in ${FILES[$d]}; do install -m644 "${SRC[$d]}/$f" "$DST/$d/$f"; done
  printf '%s\n' "${KBUILD[$d]}" > "$DST/$d/Kbuild"
done
printf 'obj-m += cam/ ccu/ leds/ waketimer/\n' > "$DST/Kbuild"
{
  echo "PACKAGE_NAME=\"$NAME\""
  echo "PACKAGE_VERSION=\"$VER\""
  echo 'MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"'
  echo 'CLEAN="true"'
  echo 'AUTOINSTALL="yes"'
  i=0
  for m in "${MODS[@]}"; do
    echo "BUILT_MODULE_NAME[$i]=\"${m#*:}\""
    echo "BUILT_MODULE_LOCATION[$i]=\"${m%%:*}/\""
    echo "DEST_MODULE_LOCATION[$i]=\"/updates/dkms\""
    i=$((i + 1))
  done
} > "$DST/dkms.conf"

# Remove the hand-installed copies first: DKMS would archive them as "original modules",
# put them back on uninstall, and then refuse to install over them at the next kernel hook.
K=$(uname -r)
for m in "${MODS[@]}"; do rm -f "/lib/modules/$K/extra/${m#*:}.ko" "/lib/modules/$K/extra/${m#*:}.ko".bak-*; done
dkms add "$NAME/$VER"
dkms build "$NAME/$VER"
dkms install "$NAME/$VER" --force
depmod "$K"
dkms status "$NAME"
for m in "${MODS[@]}"; do modinfo -F filename "${m#*:}"; done
