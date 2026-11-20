# Kernel and NVIDIA driver patches

The laptop runs [Omarchy's](https://github.com/omacom/omarchy-pkgs) `linux-omarchy-aarch64` kernel
(7.3 series), which carries the N1X platform support (MediaTek platform, FF-A EC, power wrapper,
audio, USB4 and more). That work is theirs and NVIDIA's and is not copied here. These three patches
are what this machine needs on top.

| Patch | Applies to | Purpose |
|---|---|---|
| `1116-ACPI-OSI-...Yoga-9-2-in-1-16N1X11.patch` | kernel | Adds the 83N7 to the list of machines that must not be told the OS is "Windows 2022". Without it the firmware hides the power controller and the keyboard, touchpad, audio, USB4 and EC never power on. The same effect without the patch: `acpi_osi="!Windows 2022"` on the kernel command line. |
| `1117-ACPI-processor-...firmware-disabled-platform-_LPI-states.patch` | kernel | Lets suspend-to-idle use the deep idle states the firmware marks as disabled (it enables them only for Windows). Sleep draw drops from about 5.5 W to about 1.0 W. |
| `nvidia-0010-let-the-n1x-gpu-suspend-again.patch` | NVIDIA open kernel modules 620.70.06 | Driver 620 lists the N1X GPU (GB20B / GB20C) as "power management unsupported", so every suspend is refused (`NVRM: PM suspend notifier failed: 0x56`). This removes the two chips from that list, as in 615. Still needed with 620.73.04. |

Also required and already upstream in NVIDIA's kernel tree: the FF-A `notify_id` fix
(NVIDIA/NV-Kernels #653, by David Cemin). Without it EC notifications (lid, UCSI) are lost.

## Other boot requirements

- Kernel command line: `cma=256M` (the camera's capture buffers and the NVIDIA driver share the CMA
  pool) and, unless patch 1116 is applied, `acpi_osi="!Windows 2022"`.
- NVIDIA driver 620.70.06 raises the SoC power limit this firmware applies from 35 W (driver 615) to 70 W.
  If the laptop is booted on the charger the limit reads 45 W until the charger is replugged.
- Flatpak applications need the NVIDIA GL extension that matches the driver
  (`org.freedesktop.Platform.GL.nvidia-620-70-06`). x86 games running through FEX broke on native
  Wayland with 620; `--display-driver x11` works.
- Do not let a full system upgrade replace the kernel or the NVIDIA packages with repository builds
  that lack these patches (`IgnorePkg` in `/etc/pacman.conf`).
