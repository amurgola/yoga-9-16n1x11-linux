#!/usr/bin/env python3
"""Extract the ST VD55G0 sensor firmware patch from the Windows camera sensor driver.

The IR camera's sensor needs a small firmware patch at every power-on. It belongs to
STMicroelectronics and is shipped inside NVIDIA's Windows driver (nvMIPICamSensor.sys),
so this repository does not contain it. This tool finds it in your own copy of that
driver and writes it where the Linux driver looks for it.

  sudo ./extract-vd55g0-patch.py /path/to/Windows [OUT]

/path/to/Windows is the mounted Windows partition (read-only is fine) or the .sys file
itself. OUT defaults to /lib/firmware/nvidia/n1x/vd55g0-patch.bin.

The patch is identified by its SHA-256, so a different driver version that carries a
different patch is reported instead of being installed blindly.
"""
import glob, hashlib, os, sys

HEADER = bytes.fromhex("5600020d")      # patch header as written to sensor address 0x2000
LENGTH = 392
SHA256 = "eab298f7336f51f842ca51fb36ec28c1def70327f877087838f44423db168acb"
OUT = "/lib/firmware/nvidia/n1x/vd55g0-patch.bin"

def candidates(path):
    if os.path.isfile(path):
        return [path]
    pat = os.path.join(path, "Windows/System32/DriverStore/FileRepository/nvmipicamsensor.inf_arm64_*/nvMIPICamSensor.sys")
    return sorted(glob.glob(pat), key=os.path.getmtime, reverse=True)

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = sys.argv[2] if len(sys.argv) > 2 else OUT
    files = candidates(sys.argv[1])
    if not files:
        sys.exit("no nvMIPICamSensor.sys found under " + sys.argv[1])
    for f in files:
        data = open(f, "rb").read()
        pos = data.find(HEADER)
        while pos >= 0:
            blob = data[pos:pos + LENGTH]
            if hashlib.sha256(blob).hexdigest() == SHA256:
                # Windows writes 400 bytes: the patch followed by a repeat of its last 8.
                # That is the form this driver was tested with, so reproduce it.
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with open(out, "wb") as o:
                    o.write(blob + blob[-8:])
                print(f"patch found in {f} at offset {pos}; wrote {out} ({LENGTH + 8} bytes)")
                return
            pos = data.find(HEADER, pos + 1)
    sys.exit("the known VD55G0 patch was not found (different driver version?). Files checked:\n  " + "\n  ".join(files))

if __name__ == "__main__":
    main()
