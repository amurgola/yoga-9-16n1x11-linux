# Hardware notes: what was learned about the 83N7

Facts established on one Lenovo Yoga 9 2-in-1 16N1X11 (83N7, 64 GB), firmware as shipped in late 2026.
Addresses are physical. Treat everything as specific to this model unless stated otherwise.

## SoC power limits (firmware power block)

Found by other N1X owners on the HP OmniBook (see Credits in the README); confirmed and extended here.

Block at `0x1C238000`, values in mW:

| Offset | Meaning |
|---|---|
| `0x000` | commit doorbell: write 1 after changing a request slot |
| `0x100` .. `0x11C` | OS request slots: PL1, PL2, -, -, SysPL1..4 |
| `0x120` .. | the embedded controller's values |
| `0x160`, `0x164` | effective PL1, PL2 |
| `0x700`, `0x704` | PL1 bounds |
| `0x800`, `0x804` | SoC power, average and instantaneous |
| `0x80C`, `0x810` | system power |
| `0x818`, `0x830` | SoC and GPU temperature (deci-Kelvin) |

- Writing PL1/PL2 into the OS slots and ringing the doorbell **lowers** the SoC budget within about
  two seconds (70 W to 25 W held under load). Raising above the EC's value was not attempted.
- The ACPI thermal zones `\_TZ.PSOC` and `\_TZ.PSYS` expose SoC and system power without root:
  mW = temp / 100 + 2732.
- The EC's limit depends on the NVIDIA driver: 35 W with 615.78.08, 70 W with 620.70.06, and 45 W if
  the machine was booted on the charger (70 W after replugging it).
- The EC "thermal mode" byte (`0xFE0B034D`, via `\_SB.GZFD.WMAA`) had no effect on the limit.

`hw/tools/soc-power-watch.py` samples the block; `hw/tools/soc-pl-test.py` is a guarded test that lowers
PL1/PL2 and restores them; the Power Deck's helper uses the same mechanism and never raises a limit.

## Sleep

- The firmware clears the Enabled flag of every cluster, package and system `_LPI` state unless
  `\_SB.PEPD.ELST(1)` has been called, which only Windows does. Linux was left with WFI and core-off:
  5.5 W asleep. Kernel patch 1117 takes those states for suspend-to-idle: about 1.0 W, and the deepest
  state (Standby-DRIPS) is reached.
- NVIDIA driver 620 refuses to suspend this GPU unless patched (`kernel/`).
- **Long sleeps:** single sleeps of 10.3 h and 14 h did not wake (power light pulsing, no reaction to
  lid, keys or power button; forced power-off). Sleeps up to 8.9 h woke. The owner of a Surface Laptop
  Ultra sees the same chip die inside Standby-DRIPS on long sleeps. The workaround here is
  `hw/waketimer/`: wake every two hours and go straight back to sleep. Nights of 9 h have woken
  normally at an unchanged 1.0 W; longer nights are not yet confirmed.
- There is no usable wake alarm: `rtc-efi` cannot wake the machine, and the ACPI Time-and-Alarm
  device (`ACPI000E`) is a stub in the EC (it accepts values and stores nothing). The SoC has eight
  always-on memory-mapped generic-timer frames (GTDT, block `0x1C430000`); Linux uses frame 0.
  `n1x_wake_timer` uses frame 1 (`0x1C450000`, GSI 731) as a wake source.

## Embedded controller

- EC RAM is reached over FF-A through the ACPI methods `\_SB.RECM` / `\_SB.WECM`.
- Fn hotkeys arrive as `Notify(\_SB.WMIU, 0xD0)`; `_WED(0xD0)` returns the key code (0x3E = microphone
  mute). The key produces no input event without a driver.
- The F4 microphone-mute light: `\_SB.WMIU.WMSK(0, 2, Buffer {1})` on, `Buffer {2}` off.
- Entering s2idle writes `0xBB` to EC `0xFE0B0361` (pulsing power light); leaving writes `0xCC`.

## Cameras

- Webcam OV08X40 on `\_SB.CAMF` (I2C0 0x10, CSI port 0); IR sensor VD55G0 on `\_SB.CAMI` (I2C4 0x10,
  CSI port 2) with a TI LM3644 LED driver at 0x63. Each has two GPIOs: power and reset (front: 34, 39).
- **Indicator light.** It is not a GPIO and not driven by the sensor. The camera co-processor (CCU)
  firmware owns it and signals the secure firmware. Windows' `nvCCU.sys` evaluates
  `\_SB.CCU0._DSM` (`810afc1e-14a8-4e23-b1ef-3d16ea4ec531`) function 1 and writes the result (4 here) to
  CCU+0x30000 before the firmware starts. With 4 the light comes on at stream start; it goes off on
  the stream-off message (feature 2, command 5). The value 1 used on the Surface leaves it dark.
- Windows boots the CCU for every camera session and shuts it down afterwards. Booting it once and
  leaving it running works under Linux.
- Privacy shutter sensor: GPIO 128, input, 1 = open.
- The IR sensor needs a firmware patch at power-on (cut 1.1, patch 13.2). The sensor's own auto
  exposure meters the whole image; with a dark background it saturates a near subject.

## GPIO controller

`\_SB.GIO0` first region `0x1002D000`: direction `+0x000`, output `+0x100`, input `+0x200`
(32 pins per word, words 0x10 apart), mode `+0x300` (4 bits per pin).

## Things that are stubs or dead ends on this model

- ACPI wake alarm (above).
- Strobing the IR LEDs from the sensor's GPIOs as Windows configures them: no light under Linux.
- NVIDIA Broadcast / Maxine video effects: Windows-on-Arm only for this chip; the Linux SDK is x86-64 only.
