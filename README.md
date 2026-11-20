# Linux on the Lenovo Yoga 9 2-in-1 16N1X11 (83N7)

Working notes, drivers and scripts for running Arch Linux ARM on the Lenovo Yoga 9 2-in-1 16N1X11
(machine type 83N7) with the NVIDIA N1X SoC and RTX Spark GPU.

This is one owner's bring-up of one laptop. It is not a distribution and not an installer. Each
directory covers one piece that was made to work, with the code that does it and what is known about
its limits. Most of it builds on other people's work; see [Credits](#credits).

**Tested configuration:** 64 GB model, Arch Linux ARM with the Omarchy kernel
(`linux-omarchy-aarch64` 7.3, locally rebuilt with the patches in `kernel/`), NVIDIA open driver
620.70.06, KDE Plasma 6.8 on Wayland. Nothing here has been tried on another unit, another firmware
version or another distribution.

## Use at your own risk

Everything here is provided as is, with no warranty of any kind and no support. It is unofficial and
not affiliated with Lenovo, NVIDIA, MediaTek or Microsoft.

Several pieces write to hardware registers, load kernel modules, change power limits or change how
you log in. They can hang or reset the machine, lose unsaved work, drain the battery, or lock you
out of an account if applied carelessly. Nothing here has been tested beyond one laptop. Read the
code before running it, keep a way to recover (a second boot entry, your password, a backup), and
accept that whatever happens to your device and data is your responsibility.

## What works

| Feature | State | Where |
|---|---|---|
| Boot, GPU, Wi-Fi, Bluetooth, keyboard, touchpad, touchscreen | works with the Omarchy kernel plus one quirk | `kernel/` |
| Sleep (suspend-to-idle) | about 1.0 W asleep, down from 5.5 W | `kernel/` patch 1117 |
| Waking after long sleeps | workaround: timed wake every two hours | `hw/waketimer/` |
| GPU power limit | 70 W with driver 620 (35 W with 615) | `kernel/`, `docs/hardware-notes.md` |
| Power control and readout | SoC limit, core frequency caps, per-application CPU limits, FPS readout, profiles | `power/` |
| Speakers and internal microphones | stereo, woofers and tweeters, Lenovo tuning | `audio/` |
| Webcam | 3840x2400 sensor, 1920x1200 at 30 fps on the desktop | `hw/camera/` |
| IR camera | 640x480 grey at 30 fps | `hw/camera/` |
| Camera indicator light | on while a camera streams | `hw/camera/` |
| F4 microphone-mute key and its light | works | `hw/leds/` |
| Face login | Howdy on the IR camera: sudo, lock screen, login screen | `face-login/` |
| Touchpad haptic strength | set at boot and after resume | `config/touchpad/` |
| Kernel module rebuilds | one DKMS package for the four modules | `hw/dkms/` |

## Current limitations

**Sleep and power**
- Single sleeps longer than about nine hours did not wake (10.3 h and 14 h; forced power-off needed).
  The cause is unknown. The timed wake is a workaround, confirmed for a nine-hour night and not yet
  for longer ones. Each timed wake costs a few seconds awake; average sleep draw stayed at 1.0 W.
- The laptop sometimes wakes by itself with the lid closed, for a reason not yet found. The desktop
  puts it back to sleep within seconds.
- Booted on the charger, the SoC power limit reads 45 W until the charger is replugged (then 70 W).
- The low-idle target (5 to 7 W with the screen on) has not been measured against a tuned profile.
  Profiles are applied by hand; nothing switches them when an application starts. The GPU clock
  ceiling control is untested.

**Cameras**
- Only one camera can stream at a time; they share a capture path.
- The webcam picture is usable but grainy in low light, and streaming costs about 1.5 CPU cores
  (software image processing; there is no hardware ISP support).
- The IR LEDs stay on continuously while the IR camera runs. Windows pulses them.
- About one stream start in forty delivers no frames; the driver restarts it after two seconds.
- One hard system crash happened right after starting a camera application and was never reproduced.
- Two firmware files and the colour calibration have to come from your own Windows installation.

**Audio**
- The headphone jack and headset microphone have not been tested.
- The amplifier firmware has to come from your own Windows installation.

**Face login**
- Convenience, not security: infrared face matching is easier to fool than a password.
- It needs a model enrolled for each lighting condition, and it cannot run while the webcam is in use.
- The lock screen needs one key press before it starts looking.

**Maintenance**
- The kernel is a manual build with local patches. A full system upgrade must not replace it or the
  NVIDIA packages.
- Nothing here is upstream yet. The patches in `kernel/` are candidates.

**Not working or not started**
- NPU / DLA (see johannhartmann's project under Credits).
- NVIDIA Broadcast-style camera effects (not available for this chip on Linux).
- On the 32 GB model part of the memory is reserved for the GPU by firmware; that was not solved here.

## Layout

| Directory | Content |
|---|---|
| `kernel/` | two kernel patches and one NVIDIA driver patch, with boot requirements |
| `hw/camera/` | camera driver, co-processor boot module, libcamera patch, tools |
| `hw/leds/` | F4 key and light driver, plus a user service that follows the microphone's mute state |
| `hw/waketimer/` | timer wake from sleep, sleep hook and log |
| `hw/dkms/` | packages the four modules above as one DKMS package |
| `hw/tools/` | probes: SoC power sampling, power-limit test, EC access, GPIO dump, crash recorder |
| `power/` | "Power Deck": command-line tool, root helper, Plasma widget, FPS counter layer |
| `audio/` | package recipe and the modified speaker configuration |
| `face-login/` | Howdy setup notes and the lock-screen PAM file |
| `config/touchpad/` | haptic strength script, udev rule and sleep hook |
| `windows/ledsnoop/` | Windows capture tool used to investigate the indicator light |
| `docs/hardware-notes.md` | register maps and findings in one place |

## Suggested order

1. Kernel with the patches in `kernel/`, the two command-line options, NVIDIA 620.70.06 with its patch.
2. `audio/`.
3. `hw/camera/`: copy the two firmware files, build the patched libcamera, run `packaging/install.sh`.
4. `hw/leds/install.sh root` as root, then `hw/leds/install.sh` as your user.
5. `hw/waketimer/install.sh`.
6. `power/install.sh root` as root, then `power/install.sh` as your user.
7. `face-login/` if wanted.

Steps 3 to 5 use DKMS, so the modules are rebuilt when kernel headers are installed.

## What is deliberately not here

Nothing that belongs to a vendor is included:

- no firmware: not the camera co-processor image, not the IR sensor patch, not the Cirrus amplifier
  firmware or tuning files;
- no calibration data: the webcam colour matrices come from NVIDIA's Windows tuning database and are
  only described, with a tool that reads them from your own installation;
- no firmware tables (DSDT and others), no Windows driver binaries, no disassembly.

What is included from observation of this laptop: register write sequences and register state
recorded on its own buses (in the camera driver, as in the project it derives from), and
descriptions of what the Windows drivers do. If you hold rights in something here and think it
should not be published, please open an issue.

## Credits

This would not exist without the following people and projects. Thank you.

- **ikegam** for [surface-ultra-camera](https://github.com/ikegam/surface-ultra-camera): the camera
  driver, the co-processor boot code and the `ccusnoop` capture tool that the camera work here is a
  port of, including the fix for slow power-controller replies after long sleeps. Also for
  [surface-ultra-misc](https://github.com/ikegam/surface-ultra-misc), whose sleep research on the
  same chip informed the long-sleep workaround. That project in turn builds on Surface work by teo-casares.
- **Omarchy** ([omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)) and its contributors for
  the `linux-omarchy-aarch64` kernel and its N1X patch series, and for the NVIDIA 620 packaging with
  its ARM fixes. Everything here runs on that kernel.
- **NVIDIA** for the [open GPU kernel modules](https://github.com/NVIDIA/open-gpu-kernel-modules), the
  N1X platform work in [NV-Kernels](https://github.com/NVIDIA/NV-Kernels) (including David Cemin's
  FF-A notification fix), and the SoundWire audio configuration in
  [alsa-ucm-conf #862](https://github.com/alsa-project/alsa-ucm-conf/pull/862).
- **lozzamatron** and **kk1987** for finding the SoC power-limit block on the HP OmniBook X 14, and
  **seankd3** for the GPU clock-cap work on the ASUS ProArt P16, all in
  [open-gpu-kernel-modules #1521](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1521).
- **johannhartmann** for
  [asus-proart-p16-rtx-spark-linux](https://github.com/johannhartmann/asus-proart-p16-rtx-spark-linux)
  (the power-limit request-slot experiments, and the kernel patch set that carries ST's VD55G0 sensor
  driver) and [n1x-npu-linux](https://github.com/johannhartmann/n1x-npu-linux).
- **jerryabramson** for [yoga-rtx](https://github.com/jerryabramson/yoga-rtx), earlier work on this
  same laptop.
- **STMicroelectronics** for the VD55G0 Linux driver, the source of the IR sensor's register map.
- The **libcamera** project, whose software ISP makes the webcam usable without hardware ISP support.
- **boltgolt** and contributors for [Howdy](https://github.com/boltgolt/howdy), and **Davis King** for
  dlib and its face models.
- The **alsa-ucm-conf**, **DKMS** and **acpi_call** projects.

Most of the investigation and code here was produced by the owner working with Anthropic's Claude
(Claude Code) on the machine itself. Mistakes are ours, not those of the people credited above.

## License

GPL-2.0-only, see `LICENSE`. The camera driver and the Windows capture tool derive from GPL-2.0 code
by ikegam. Exceptions are marked in the files themselves: the UCM configuration in `audio/` is
BSD-3-Clause (NVIDIA, with local changes), the libcamera patch follows libcamera's licences
(LGPL-2.1-or-later for the code it touches), and the libcamera tuning and configuration files are CC0-1.0.
