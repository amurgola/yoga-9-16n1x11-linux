#!/usr/bin/env python3
"""Lenovo 83N7 (NVIDIA N1X): test whether the OS can LOWER the SoC power limit at runtime.

Register map of the firmware power block at 0x1C238000 (mW), from the ASUS ProArt P16 study
(johannhartmann/asus-proart-p16-rtx-spark-linux, experiments/gpu-syspl3) and our own dumps:
  0x000            commit doorbell (write 1)
  0x100..0x11C     OS requests   [PL1, PL2, -, -, SysPL1, SysPL2, SysPL3, SysPL4]   (0 = no request)
  0x120..0x13C     EC values
  0x160..0x17C     effective limits
  0x700/0x704      PL1 bounds (min, max)
The P16 study wrote SysPL3 (0x118) + doorbell and saw the effective value follow. This script
does the same for PL1/PL2 (0x100/0x104), which nobody has reported trying, and only downwards.

  sudo hw/tools/soc-pl-test.py [--watts 25] [--seconds 30] [--no-load]

It refuses to run unless: no OS request is already set, the target is below the current
effective PL1 and inside the firmware bounds, and the SoC is below 85 C. On any exit path it
clears its request (writes 0 + doorbell) and checks that the effective limit came back.
"""
import argparse, mmap, os, signal, struct, subprocess, sys, time

BASE = 0x1C238000
# GPU load generator, relative to the invoking user's home (override with N1X_LLAMA_BENCH / N1X_LOAD_MODEL)
HOME_BIN = os.environ.get("N1X_LLAMA_BENCH", "src/llama.cpp/build/bin/llama-bench")
MODEL = os.environ.get("N1X_LOAD_MODEL", "models/model.gguf")   # any large GGUF model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watts", type=float, default=25.0)
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--no-load", action="store_true")
    a = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("run with sudo")
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
    rd = lambda off: struct.unpack_from("<I", mm, off)[0]

    def wr(off, val):
        struct.pack_into("<I", mm, off, val)

    def show(tag):
        print(f"{tag}: OS req PL1/PL2 = {rd(0x100)}/{rd(0x104)}  EC = {rd(0x120)}/{rd(0x124)}  "
              f"effective = {rd(0x160)}/{rd(0x164)} mW  SoC now {rd(0x804) / 1e3:.1f} W  "
              f"{rd(0x818) / 10 - 273.15:.0f} C")

    show("before")
    target = int(a.watts * 1000)
    eff1, eff2 = rd(0x160), rd(0x164)
    lo, hi = rd(0x700), rd(0x704)
    if any(rd(0x100 + 4 * i) for i in range(8)):
        sys.exit("an OS request is already set; not touching it")
    if not (10000 <= target < eff1 and lo <= target <= hi):
        sys.exit(f"target {target} mW must be >= 10 W, below the effective PL1 ({eff1}) and within bounds ({lo}..{hi})")
    if rd(0x818) / 10 - 273.15 >= 85:
        sys.exit("SoC too warm for a clean test")

    state = {"set": False}

    def clear(*_):
        if state["set"]:
            wr(0x100, 0); wr(0x104, 0); wr(0x000, 1)
            state["set"] = False
            for _ in range(30):
                if rd(0x160) == eff1 and rd(0x164) == eff2:
                    break
                time.sleep(0.1)
            show("restored")
            print("RESTORE OK" if (rd(0x160), rd(0x164)) == (eff1, eff2) else
                  "WARNING: effective limit did not return to its old value (a reboot resets it)")

    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    proc = None
    try:
        state["set"] = True
        wr(0x100, target); wr(0x104, target); wr(0x000, 1)
        for _ in range(30):
            if rd(0x160) == target:
                break
            time.sleep(0.1)
        show("after request")
        if rd(0x160) != target:
            print("RESULT: the firmware did not take the PL1 request (effective unchanged)")
            return
        print(f"RESULT: effective PL1 followed the OS request -> {target / 1e3:.0f} W")
        if not a.no_load:
            uid, gid = int(os.environ.get("SUDO_UID", 0)), int(os.environ.get("SUDO_GID", 0))
            home = os.path.expanduser("~" + os.environ.get("SUDO_USER", "root"))
            proc = subprocess.Popen(
                ["timeout", str(a.seconds), os.path.join(home, HOME_BIN), "-m", os.path.join(home, MODEL),
                 "-ngl", "99", "-fa", "1", "-p", "2048", "-n", "0", "-r", "100000"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, user=uid, group=gid,
                extra_groups=os.getgrouplist(os.environ.get("SUDO_USER", "root"), gid), env={**os.environ, "HOME": home})
        t0 = time.time()
        while time.time() - t0 < a.seconds:
            try:
                g = subprocess.run(["nvidia-smi", "--format=csv,noheader", "--query-gpu=clocks.gr,power.draw"],
                                   capture_output=True, text=True, timeout=5).stdout.strip()
            except Exception:
                g = "?"
            print(f"  t={time.time() - t0:4.0f}s  SoC {rd(0x804) / 1e3:5.1f} W (avg {rd(0x800) / 1e3:5.1f})  "
                  f"limit {rd(0x160) / 1e3:.0f} W  {rd(0x818) / 10 - 273.15:.0f} C  GPU {g}")
            if rd(0x818) / 10 - 273.15 >= 95:
                print("temperature stop")
                break
            time.sleep(2)
    finally:
        if proc:
            proc.terminate()
            proc.wait()
        clear()


if __name__ == "__main__":
    main()
