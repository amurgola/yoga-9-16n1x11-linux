# Cameras: webcam, IR camera and the indicator light

Kernel driver `n1x_yoga_cam` for the Lenovo Yoga 9 2-in-1 16N1X11 (83N7). It is a port of
[ikegam/surface-ultra-camera](https://github.com/ikegam/surface-ultra-camera) (GPL-2.0), which drives the
same SoC camera path on the Microsoft Surface Laptop Ultra. Read that project's `docs/how-it-works.md`
for the architecture; it applies here unchanged.

| | Webcam | IR camera |
|---|---|---|
| Sensor | OmniVision OV08X40, CSI port 0, 4 lanes | ST VD55G0, CSI port 2, 1 lane |
| Capture | 3840x2400 raw Bayer, 30 fps | 640x480 8-bit grey, 30 fps |
| Desktop | libcamera software ISP, 1920x1200 | passed through by libcamera |
| Lighting | | two IR LEDs behind a TI LM3644 (I2C4, 0x63) |

## What comes from where

| File | Content | Source |
|---|---|---|
| `sucam_main.c`, `sucam_hw.c`, `sucam_mc.c`, `sucam.h`, `ir_tables.h` | driver core, SoC receive path | surface-ultra-camera, with edits for this machine |
| `sucam_vd55g0.c` | IR sensor and IR LED driver | written for this port; register map from STMicroelectronics' `vd55g0` Linux driver |
| `ccu_replay.h`, `golden_mmio.h`, `golden_omux_all.h` | co-processor messages and register state for one stream start | recorded on this laptop with ccusnoop |
| `ov08x40_win.h` | sensor register writes for 3840x2400 | recorded from the I2C bus on this laptop |
| `../n1x-ccu-boot/` | boots the camera co-processor (CCU) firmware | surface-ultra-camera `surface_ccu_boot.c`, with edits |

## What you must supply yourself

Two firmware files are vendor property and are not in this repository. Both are on the laptop's
Windows installation.

1. **CCU firmware** `nvCCU.img`: copy
   `C:\Windows\System32\DriverStore\FileRepository\nvccu.inf_arm64_*\nvCCU.img` (version 2.15 was used)
   to `/lib/firmware/nvidia/n1x/nvCCU.img`.
2. **IR sensor patch**: `sudo ../tools/extract-vd55g0-patch.py /path/to/mounted/Windows` finds it inside
   `nvMIPICamSensor.sys` (checked by SHA-256) and writes `/lib/firmware/nvidia/n1x/vd55g0-patch.bin`.

Optional: `../tools/win-ccm-extract.py` prints the colour matrices and white-balance gains that were
calibrated for this sensor, from the Windows tuning database (`nvcamavs.inf_arm64_*`). The
`ov08x40.yaml` shipped here is a generic one; entering the calibrated matrices into it gives clearly
better colour. The calibration data itself is vendor property and is not included.

## Install

    sudo packaging/install.sh

It builds both modules through DKMS (`hw/dkms/install.sh`) and installs the module options, the
libcamera and WirePlumber configuration and a Firefox preference. Requirements: `cma=256M` on the
kernel command line, DKMS, kernel headers, and the patched libcamera in `../libcamera-n1x/` for a
full-field picture. Log out and in afterwards.

Module options (`packaging/modprobe.conf`):

- `n1x_ccu_boot go=1 ctrl=4`: `go=1` actually boots the CCU. `ctrl=4` is the value Windows writes to
  CCU+0x30000 on this laptop (`\_SB.CCU0._DSM` function 1). It tells the firmware that it owns the
  **camera indicator light**. The Surface code writes 1, and with that the light never comes on here.
- `n1x_yoga_cam mdev_name=mtk-seninf ir=1`: `ir=1` registers the IR camera as a second device.

IR tuning parameters, all changeable at run time under `/sys/module/n1x_yoga_cam/parameters/`:
`ir_torch` (LED current code, default 48, about 1.4 mA per code and LED; 0 selects the strobed mode),
`ir_ae_target` (auto-exposure target in percent, default 14; Windows uses 30), `ir_mbps` (MIPI rate, 1500).

## Behaviour and limits

- **One camera at a time.** Both sensors end in the same capture unit. The second stream gets `EBUSY`.
- **Indicator light:** on while either camera streams, off after. It also needs the driver's
  stream-off message (`ft2 0x5`), which this port adds.
- **IR LEDs run continuously** while the IR camera streams. Windows pulses them with each exposure;
  the sensor GPIO settings Windows uses do not fire them under Linux and the reason is unknown.
- **Stream that starts with no frames:** seen about once in 40 starts. The driver restarts the stream
  after 2 s without frames.
- **Privacy shutter:** a physical cover; the camera keeps streaming black frames and the light stays on,
  as on Windows. Its sensor is GPIO 128 (1 open, 0 closed); nothing uses it yet.
- **Webcam picture:** usable, still grainy in low light. A 15 fps low-light mode is blocked because the
  sensor's init table overrides the frame length. Streaming costs about 1.5 CPU cores.
- **One unexplained hard crash** happened right after starting a camera application (CMA pool
  exhaustion is suspected; never reproduced).

## Safety notes for anyone changing this driver

- Never read camera-island registers while the island is unpowered: the bus stalls and the task
  cannot be killed.
- Never set camsv `FORMAT_TAG2` bit 21: the machine freezes.
- The HFRP power controller counts "on" requests. Sending them at every stream start overflowed it
  and the SoC reset itself. Request once per power cycle.
- Never trust a payload read from a polled mailbox capture. Derive values from register dumps or
  from the Windows driver.

`test-capture.sh` and `ir-test.sh` are the first-light test scripts used during the port.
