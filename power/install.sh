#!/bin/bash
# Power Deck install. User part (no root): CLI + Plasma widget.
#   ./install.sh            install/update CLI and widget
#   sudo ./install.sh root  install/update the root helper (SoC power readout, CPU/GPU caps)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [[ ${1:-} == root ]]; then
  [[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
  install -Dm755 "$here/n1x-powerd.py" /usr/local/lib/n1x-power/n1x-powerd.py
  cat > /etc/systemd/system/n1x-powerd.service <<UNIT
[Unit]
Description=N1X power deck helper (SoC power readout, CPU/GPU caps)
[Service]
ExecStart=/usr/bin/python3 -I /usr/local/lib/n1x-power/n1x-powerd.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable n1x-powerd.service
  systemctl restart n1x-powerd.service
  systemctl --no-pager --lines=3 status n1x-powerd.service || true
  exit 0
fi
[[ $EUID -ne 0 ]] || { echo "run the user part without sudo" >&2; exit 1; }
install -Dm755 "$here/n1xpower" "$HOME/.local/bin/n1xpower"
# frame-counter Vulkan layer (feeds the FPS readout); DISABLE_N1X_FPS=1 turns it off per program
gcc -O2 -shared -fPIC -fvisibility=hidden -o "$here/fps-layer/libn1x_fps.so.new" "$here/fps-layer/n1x_fps.c"
install -Dm755 "$here/fps-layer/libn1x_fps.so.new" "$HOME/.local/lib/n1x-power/libn1x_fps.so"
rm -f "$here/fps-layer/libn1x_fps.so.new"
mkdir -p "$HOME/.local/share/vulkan/implicit_layer.d"
sed "s|@LIB@|$HOME/.local/lib/n1x-power/libn1x_fps.so|" "$here/fps-layer/n1x_fps.json.in" > "$HOME/.local/share/vulkan/implicit_layer.d/n1x_fps.json"
stage=$(mktemp -d)
cp -r "$here/plasmoid/." "$stage/"
sed -i "s|@N1XPOWER@|$HOME/.local/bin/n1xpower|" "$stage/contents/ui/main.qml"
if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -q org.n1x.powerdeck; then
  kpackagetool6 -t Plasma/Applet -u "$stage"
else
  kpackagetool6 -t Plasma/Applet -i "$stage"
fi
rm -rf "$stage"
echo "Installed. Add it with: right-click the panel > Add or Manage Widgets > 'Power Deck'."
