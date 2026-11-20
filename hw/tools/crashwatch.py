#!/usr/bin/env python3
"""Flight recorder for a crash we cannot log: samples the system 4x a second and fsyncs every
line, so the last state before a hard freeze survives on disk.
  hw/tools/crashwatch.py OUTDIR [seconds=900]
Files: samples.log (camera openers, camera-related processes, memory/CMA, GPU, load),
kernel.log (live kernel messages), procs.log (full process list every 2 s)."""
import glob, os, subprocess, sys, threading, time

out = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 900
os.makedirs(out, exist_ok=True)

def writer(name):
    f = open(os.path.join(out, name), "a", buffering=1)
    def w(line):
        f.write(line + "\n"); f.flush(); os.fsync(f.fileno())
    return w

def kernel():
    w = writer("kernel.log")
    p = subprocess.Popen(["journalctl", "-k", "-f", "-n", "5", "-o", "short-precise", "--no-pager"],
                         stdout=subprocess.PIPE, text=True)
    for line in p.stdout:
        w(line.rstrip())

def rd(p):
    try: return open(p).read()
    except OSError: return ""

def openers():
    res = []
    for d in glob.glob("/proc/[0-9]*"):
        try:
            hits = sorted({os.readlink(f).rsplit("/", 1)[-1] for f in glob.glob(d + "/fd/*")
                           if os.readlink(f).startswith(("/dev/video", "/dev/media", "/dev/v4l-subdev"))})
        except OSError:
            continue
        if hits:
            res.append(f"{rd(d + '/comm').strip()}[{d[6:]}]:{'+'.join(hits)}")
    return " ".join(res) or "-"

threading.Thread(target=kernel, daemon=True).start()
ws, wp = writer("samples.log"), writer("procs.log")
t0 = time.time(); n = 0
while time.time() - t0 < secs:
    mem = {l.split(":")[0]: l.split()[1] for l in rd("/proc/meminfo").splitlines()
           if l.startswith(("MemAvailable", "CmaFree", "MemFree"))}
    cam = [f"{rd(d + '/comm').strip()}[{d[6:]}]" for d in glob.glob("/proc/[0-9]*")
           if rd(d + "/comm").strip() in ("qcam", "cam", "pipewire", "wireplumber", "firefox")]
    ws(f"{time.strftime('%T')}.{int(time.time() * 1000) % 1000:03d} load={rd('/proc/loadavg').split()[0]} "
       f"memavail={mem.get('MemAvailable')} cmafree={mem.get('CmaFree')} "
       f"cam_users={rd('/sys/module/n1x_yoga_cam/refcnt').strip()} openers=[{openers()}] procs={','.join(cam)}")
    if n % 8 == 0:
        try:
            g = subprocess.run(["nvidia-smi", "--format=csv,noheader", "--query-gpu=clocks.gr,power.draw,memory.used,utilization.gpu"],
                               capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception as e:
            g = f"nvidia-smi failed: {e}"
        ws(f"{time.strftime('%T')} gpu: {g}")
        wp(f"=== {time.strftime('%T')}\n" + subprocess.run(["ps", "-eo", "pid,pcpu,rss,stat,comm", "--sort=-pcpu"],
                                                          capture_output=True, text=True).stdout[:2500])
    n += 1
    time.sleep(0.25)
ws("END (no crash during the watch)")
