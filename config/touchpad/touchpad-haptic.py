#!/usr/bin/env python3
# Read/set the haptic click intensity of the Lenovo 83N7 touchpad
# (Elan 04F3:3355 behind ACPI WACF2205). HID feature report 0x09 holds two
# Intensity values (0..100, presumably press and release), the same setting
# Windows' haptic-intensity slider writes. Needs root (hidraw is 0600).
#   (the pad refuses reads of this report, so values can only be set)
#   touchpad-haptic.py 40         set both to 40
#   touchpad-haptic.py 40 20      set press=40 release=20
import fcntl, glob, os, sys

HID_ID = "0018:04F3:3355"
RID, LEN = 0x09, 3  # report id + 2 bytes

def ioc(nr, size):  # _IOC(_IOC_READ|_IOC_WRITE, 'H', nr, size)
    return (3 << 30) | (size << 16) | (ord('H') << 8) | nr

def hidraw():
    for h in glob.glob("/sys/class/hidraw/hidraw*"):
        if HID_ID in os.path.realpath(os.path.join(h, "device")):
            return "/dev/" + os.path.basename(h)
    sys.exit(f"touchpad {HID_ID} not found")

# The pad rejects GET_REPORT for 0x09 (EINVAL): it is effectively write-only,
# like on Windows, so the current value can't be shown.
if len(sys.argv) < 2:
    sys.exit(__doc__ or "usage: touchpad-haptic.py PRESS [RELEASE]  (0..100)")
vals = [int(v) for v in sys.argv[1:3]]
vals = (vals * 2)[:2] if len(vals) == 1 else vals
if not all(0 <= v <= 100 for v in vals):
    sys.exit("values must be 0..100")
dev = hidraw()
fd = os.open(dev, os.O_RDWR)
fcntl.ioctl(fd, ioc(0x06, LEN), bytearray([RID] + vals))  # HIDIOCSFEATURE
os.close(fd)
print(f"{dev}: haptic intensity set to {vals}")
