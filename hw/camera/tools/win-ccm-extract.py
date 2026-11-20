#!/usr/bin/env python3
"""Print the colour correction matrices and their white-balance gains from the Windows camera
tuning database of this laptop (NVIDIA/MediaTek nvcamavs driver, SQLite).

  tools/win-ccm-extract.py /run/media/$USER/Windows-SSD/Windows/System32/DriverStore/FileRepository/nvcamavs.inf_arm64_*/ov08x40_mipi_raw_ISP_param.db

Table isp_fwccm_Param: CCM_CT_VALID_NUM calibration lights, matrices CCM_CNV<k>_<row><col> as
13-bit signed with 512 = 1.0 (rows sum to 512), and the AWB gains CCM_AWB<k>_{R,G,B} measured
under each light (G = 512). On the 83N7's OV08X40: 0 horizon, 1 A, 2 TL84, 3 CWF, 4 D65.
Black level: isp_obc_Param OBC_OFST_* = -(64 << 12) with OBC_TUNE_BIT 12, i.e. 64 at 10 bits.
"""
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True); db.row_factory = sqlite3.Row
r = db.execute("select * from isp_fwccm_Param").fetchone()
s13 = lambda v: v - 8192 if v >= 4096 else v
for k in range(r["CCM_CT_VALID_NUM"]):
    m = [s13(r[f"CCM_CNV{k}_{i}{j}"]) / 512 for i in range(3) for j in range(3)]
    g = [r[f"CCM_AWB{k}_{c}"] / 512 for c in "RGB"]
    print(f"light {k}: AWB gains R {g[0]:.3f} G {g[1]:.3f} B {g[2]:.3f}")
    for i in range(3):
        print("   " + "  ".join(f"{x:8.4f}" for x in m[i * 3:i * 3 + 3]))
