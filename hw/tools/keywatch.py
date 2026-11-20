#!/usr/bin/env python3
"""Watch every input device for a few seconds and print the key events that arrive.
  sudo hw/tools/keywatch.py [seconds=5]
Shows the device, the raw scancode (MSC_SCAN) and the key code the kernel reports."""
import glob, os, select, struct, sys, time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5
NAMES = {1: "ESC", 59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 64: "F6", 65: "F7", 66: "F8", 67: "F9",
         68: "F10", 87: "F11", 88: "F12", 113: "MUTE", 114: "VOLUMEDOWN", 115: "VOLUMEUP", 248: "MICMUTE",
         224: "BRIGHTNESSDOWN", 225: "BRIGHTNESSUP", 464: "FN", 190: "F20", 148: "PROG1", 149: "PROG2",
         202: "PROG3", 203: "PROG4", 240: "UNKNOWN", 425: "PRESENTATION", 212: "CAMERA", 582: "VOICECOMMAND"}
if os.geteuid() != 0:
    sys.exit("run with sudo")
fds = {}
for path in sorted(glob.glob("/dev/input/event*")):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        name = open(f"/sys/class/input/{os.path.basename(path)}/device/name").read().strip()
        fds[fd] = f"{os.path.basename(path)} ({name})"
    except OSError:
        pass
print(f"watching {len(fds)} devices for {secs:.0f} s — press the key now")
end, scan, seen = time.time() + secs, {}, 0
while time.time() < end:
    r, _, _ = select.select(list(fds), [], [], max(0, end - time.time()))
    for fd in r:
        try:
            data = os.read(fd, 24 * 64)
        except OSError:
            continue
        for i in range(0, len(data) - 23, 24):
            _, _, etype, code, value = struct.unpack_from("qqHHi", data, i)
            if etype == 4 and code == 4:                      # EV_MSC / MSC_SCAN
                scan[fd] = value
            elif etype == 1:                                  # EV_KEY
                seen += 1
                state = {0: "release", 1: "press", 2: "repeat"}.get(value, value)
                print(f"  {fds[fd]}: key {code} {NAMES.get(code, '')} {state}  scancode {scan.get(fd, 0):#x}")
            elif etype == 5:                                  # EV_SW
                seen += 1
                print(f"  {fds[fd]}: switch {code} = {value}")
print("no key events at all" if not seen else f"{seen} events")
