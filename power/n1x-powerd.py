#!/usr/bin/env python3
"""n1x-powerd: small root helper for the Lenovo 83N7 / NVIDIA N1X power deck.

Listens on /run/n1x-powerd.sock (root:wheel 0660), one JSON object per line.
  {"cmd": "status"}                         -> SoC power block + CPU caps
  {"cmd": "set", "cpu_e_max_mhz": 1800}     -> cap the efficiency cores (0 = no cap)
  {"cmd": "set", "cpu_p_max_mhz": 2400}     -> cap the performance cores (0 = no cap)
  {"cmd": "set", "gpu_max_mhz": 1200}       -> nvidia-smi -lgc (0 = reset, -rgc)
  {"cmd": "set", "soc_limit_w": 25}         -> firmware SoC power limit (0 = firmware default)
The SoC limit uses the firmware power block's OS request slots (0x1C238100 PL1, 0x104 PL2,
commit doorbell at 0x000). It can only lower the limit below the EC's value, never raise it,
and the request is cleared when the helper stops.
"""
import glob, grp, json, mmap, os, signal, socket, struct, subprocess, sys

SOCK = "/run/n1x-powerd.sock"
BASE = 0x1C238000
GPU_MIN_MHZ, GPU_MAX_MHZ = 208, 3003
SOC_MIN_MW = 8000


def policies():
    e, p = [], []
    for d in sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*")):
        hi = int(open(d + "/cpuinfo_max_freq").read())
        (p if hi > 3000000 else e).append((d, int(open(d + "/cpuinfo_min_freq").read()), hi))
    return e, p


class Block:
    def __init__(self):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
        self.owned = False

    def w(self, off):
        return struct.unpack_from("<I", self.mm, off)[0]

    def soc_limit(self, watts):
        """Lower PL1/PL2 through the OS request slots; 0 clears our request."""
        mw = int(float(watts) * 1000)
        if mw <= 0:
            if self.owned or self.w(0x100) or self.w(0x104):
                struct.pack_into("<I", self.mm, 0x100, 0)
                struct.pack_into("<I", self.mm, 0x104, 0)
                struct.pack_into("<I", self.mm, 0x000, 1)
            self.owned = False
            return
        ec = min(self.w(0x120), self.w(0x124))
        mw = max(SOC_MIN_MW, max(self.w(0x700), mw))
        if mw >= ec:          # at or above the EC's own limit: nothing to request
            return self.soc_limit(0)
        struct.pack_into("<I", self.mm, 0x100, mw)
        struct.pack_into("<I", self.mm, 0x104, mw)
        struct.pack_into("<I", self.mm, 0x000, 1)
        self.owned = True


def status(blk):
    e, p = policies()
    cur = lambda ps: int(open(ps[0][0] + "/scaling_max_freq").read()) // 1000 if ps else 0
    out = {"ok": True,
           "cpu_e_max_mhz": cur(e), "cpu_p_max_mhz": cur(p),
           "cpu_e_range_mhz": [e[0][1] // 1000, e[0][2] // 1000] if e else [0, 0],
           "cpu_p_range_mhz": [p[0][1] // 1000, p[0][2] // 1000] if p else [0, 0]}
    if blk:
        out.update(soc_limit_w=blk.w(0x100) / 1e3, soc_limit_range_w=[SOC_MIN_MW / 1e3, min(blk.w(0x120), blk.w(0x124)) / 1e3],
                   pl1_w=blk.w(0x160) / 1e3, pl2_w=blk.w(0x164) / 1e3, pl_max_w=blk.w(0x168) / 1e3,
                   soc_w=blk.w(0x804) / 1e3, soc_avg_w=blk.w(0x800) / 1e3, sys_w=blk.w(0x810) / 1e3,
                   soc_c=round(blk.w(0x818) / 10 - 273.15, 1), gpu_c=round(blk.w(0x830) / 10 - 273.15, 1))
    return out


def set_cpu(ps, mhz):
    for d, lo, hi in ps:
        khz = hi if not mhz else max(lo, min(hi, int(mhz) * 1000))
        with open(d + "/scaling_max_freq", "w") as f:
            f.write(str(khz))


def set_gpu(mhz):
    mhz = int(mhz)
    if mhz <= 0:
        cmd = ["nvidia-smi", "-rgc"]
    else:
        cmd = ["nvidia-smi", "-lgc", f"{GPU_MIN_MHZ},{max(GPU_MIN_MHZ, min(GPU_MAX_MHZ, mhz))}"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    return (r.stdout + r.stderr).strip()[-300:]


def handle(req, blk):
    if req.get("cmd") == "status":
        return status(blk)
    if req.get("cmd") == "set":
        e, p = policies()
        msg = {}
        if "cpu_e_max_mhz" in req:
            set_cpu(e, req["cpu_e_max_mhz"])
        if "cpu_p_max_mhz" in req:
            set_cpu(p, req["cpu_p_max_mhz"])
        if "soc_limit_w" in req:
            if not blk:
                return {"ok": False, "error": "power block unavailable"}
            blk.soc_limit(req["soc_limit_w"])
        if "gpu_max_mhz" in req:
            msg["gpu"] = set_gpu(req["gpu_max_mhz"])
        out = status(blk)
        out.update(msg)
        return out
    return {"ok": False, "error": "unknown cmd"}


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")
    try:
        blk = Block()
        blk.w(0x818)
    except Exception as ex:
        print("power block unavailable:", ex, file=sys.stderr)
        blk = None
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(SOCK)
    os.chown(SOCK, 0, grp.getgrnam("wheel").gr_gid)
    os.chmod(SOCK, 0o660)
    s.listen(8)

    def stop(*_):
        if blk:
            blk.soc_limit(0)
        try:
            os.unlink(SOCK)
        except OSError:
            pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        c, _ = s.accept()
        try:
            c.settimeout(3)
            line = c.makefile("r").readline(4096)
            try:
                resp = handle(json.loads(line), blk)
            except Exception as ex:
                resp = {"ok": False, "error": str(ex)[:200]}
            c.sendall((json.dumps(resp) + "\n").encode())
        except Exception:
            pass
        finally:
            c.close()


if __name__ == "__main__":
    main()
