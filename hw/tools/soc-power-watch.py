#!/usr/bin/env python3
"""Lenovo 83N7 (NVIDIA N1X): log the SoC power-limit block while a GPU load runs. READ-ONLY.

The firmware keeps a power/thermal telemetry block at physical 0x1C238000 (the DSDT's
thermal zones read 0x1C238800..0x838 from it). On the HP OmniBook X 14 the same block
holds PL1 @0x160, PL2 @0x164, SPL1..4 @0x170..0x17C, and PL1 ramps 80 W -> 45 W under
sustained load, dragging the GPU clock down (NVIDIA/open-gpu-kernel-modules#1521).

  sudo hw/tools/soc-power-watch.py [--idle 60] [--load 480] [--cool 180] [--detach]
                                      [--no-load] [--out FILE.csv]

Phases: idle baseline, GPU load (llama-bench prompt processing, run as the invoking
user), cooldown. One CSV row every 2 s. --detach returns at once and keeps logging.
"""
import argparse, ctypes, mmap, os, subprocess, sys, time

BASE = 0x1C238000
WORDS = {  # name: offset
    "PL1": 0x160, "PL2": 0x164, "x168": 0x168, "x16C": 0x16C,
    "SPL1": 0x170, "SPL2": 0x174, "SPL3": 0x178, "SPL4": 0x17C,
    "EPL1": 0x800, "x804": 0x804, "x808": 0x808, "ESP1": 0x80C,
    "PTJK": 0x818, "x820": 0x820, "x824": 0x824, "x828": 0x828, "x82C": 0x82C,
    "PGPU": 0x830, "x834": 0x834, "x838": 0x838,
}
# GPU load generator, relative to the invoking user's home (override with N1X_LLAMA_BENCH / N1X_LOAD_MODEL)
HOME_BIN = os.environ.get("N1X_LLAMA_BENCH", "src/llama.cpp/build/bin/llama-bench")
MODEL = os.environ.get("N1X_LOAD_MODEL", "models/model.gguf")   # any large GGUF model
SMI = ["nvidia-smi", "--format=csv,noheader,nounits", "--query-gpu=clocks.gr,power.draw,temperature.gpu,"
       "utilization.gpu,clocks_event_reasons.active"]


def rd(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle", type=int, default=60)
    ap.add_argument("--load", type=int, default=480)
    ap.add_argument("--cool", type=int, default=180)
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--detach", action="store_true")
    ap.add_argument("--dump", action="store_true", help="also save the whole page once idle and once under load")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("run with sudo (needs /dev/mem)")
    uid = int(os.environ.get("SUDO_UID", "0")); gid = int(os.environ.get("SUDO_GID", "0"))
    home = os.path.expanduser("~" + os.environ.get("SUDO_USER", "root"))
    out = a.out or os.path.join(os.getcwd(), time.strftime("soc-power-%m%d-%H%M%S.csv"))
    os.makedirs(os.path.dirname(out), exist_ok=True)

    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
    word = lambda off: ctypes.c_uint32.from_buffer_copy(mm, off).value
    word(0x818)  # fail early, before detaching

    if a.detach:
        print(f"logging to {out} for {a.idle + a.load + a.cool}s (done marker: {out}.done)")
        sys.stdout.flush()
        if os.fork():
            os._exit(0)
        os.setsid()
        dn = os.open(os.devnull, os.O_RDWR)
        for i in (0, 1, 2):
            os.dup2(dn, i)

    f = open(out, "w", buffering=1)
    os.chown(out, uid, gid)
    f.write("t,phase," + ",".join(WORDS) + ",gpu_mhz,gpu_w,gpu_c,gpu_util,reasons,bat_w,ac,ec_tmp_soc\n")
    dumped = set()
    t0 = time.time(); proc = None; total = a.idle + a.load + a.cool
    while True:
        t = time.time() - t0
        if t >= total:
            break
        phase = "idle" if t < a.idle else ("load" if t < a.idle + a.load else "cool")
        if phase == "load" and proc is None and not a.no_load:
            log = open(out + ".load.log", "w"); os.chown(out + ".load.log", uid, gid)
            proc = subprocess.Popen(
                ["timeout", str(a.load), os.path.join(home, HOME_BIN), "-m", os.path.join(home, MODEL),
                 "-ngl", "99", "-fa", "1", "-p", "2048", "-n", "0", "-r", "100000"],
                stdout=log, stderr=subprocess.STDOUT, user=uid, group=gid, extra_groups=os.getgrouplist(
                    os.environ.get("SUDO_USER", "root"), gid), env={**os.environ, "HOME": home})
        for tag, at in (("idle", a.idle / 2), ("load", a.idle + a.load - 20)):
            if a.dump and tag not in dumped and t >= at and (tag == "idle" or phase == "load"):
                dumped.add(tag)  # whole 4 KiB page as 32-bit words, for decoding the layout
                with open(f"{out}.dump-{tag}", "w") as d:
                    for off in range(0, 0x1000, 16):
                        d.write(f"{off:03x}: " + " ".join(f"{word(off + i):08x}" for i in (0, 4, 8, 12)) + "\n")
                os.chown(f"{out}.dump-{tag}", uid, gid)
        vals = [str(word(off)) for off in WORDS.values()]
        try:
            smi = subprocess.run(SMI, capture_output=True, text=True, timeout=5).stdout.strip().replace(", ", ",")
        except Exception:
            smi = ",,,,"
        if smi.count(",") != 4:
            smi = ",,,,"
        bat = rd("/sys/class/power_supply/BAT0/power_now")
        row = [f"{t:.0f}", phase] + vals + [smi, f"{int(bat) / 1e6:.2f}" if bat else "",
                                           rd("/sys/class/power_supply/ADP0/online"),
                                           rd("/sys/class/thermal/thermal_zone1/temp")]
        f.write(",".join(row) + "\n")
        if not a.detach:
            print(",".join(row)); sys.stdout.flush()
        time.sleep(max(0.0, 2 - ((time.time() - t0) % 2)))
    if proc:
        proc.wait()
    open(out + ".done", "w").close(); os.chown(out + ".done", uid, gid)


if __name__ == "__main__":
    main()
