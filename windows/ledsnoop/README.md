# ledsnoop: what does Windows switch when the camera turns on?

A Windows kernel driver and a PowerShell script used to find out how the webcam indicator light is
driven. It is [ccusnoop](https://github.com/ikegam/surface-ultra-camera/tree/main/tools/windows-ccusnoop)
by ikegam (GPL-2.0) with one addition: besides the camera co-processor mailbox and the camera register
blocks, each snapshot also contains the SoC GPIO controller page at `0x1002D000`.

It only **reads** hardware. Its single output is `C:\ledsnoop.log`. The worst realistic outcome is a
frozen or blue-screened Windows that needs a hard reboot; save your work first. Test signing lowers
Windows' driver security while it is on.

## Running it

Needs Visual Studio Build Tools with the C++ ARM64 tools, the "Windows Driver Kit Build Tools"
component, and the WDK.

1. Copy this folder to `C:\ledsnoop`.
2. Admin prompt: `bcdedit /set testsigning on`, reboot into Windows.
3. Normal PowerShell: `powershell -ExecutionPolicy Bypass -File C:\ledsnoop\led-capture.ps1`
   (one elevation prompt). The first run builds the driver. It records 4 s with the camera closed,
   opens the Camera app for 15 s, and unloads the driver while the preview is still running.
4. Admin prompt: `bcdedit /set testsigning off`, reboot.

If a non-admin shell cannot write to `C:\ledsnoop` (a folder created from Linux inherits the
drive root's security settings): `icacls C:\ledsnoop /setintegritylevel "(OI)(CI)M"`.
If the driver refuses to load, self-sign it:

    makecert -r -ss PrivateCertStore -n CN=ledsnoopTest ledsnoopTest.cer
    signtool sign /s PrivateCertStore /n ledsnoopTest /fd sha256 C:\ledsnoop\ledsnoop.sys
    certmgr /add ledsnoopTest.cer /s /r localMachine root

## Reading the log

`hw/camera/tools/gpio-bits.py LOG...` prints, for every GPIO pin, how often it was high with the
camera off and on. `hw/tools/gpio-dump.py` produces the same GPIO lines under Linux for comparison.

GPIO page layout (32 pins per word, words 0x10 apart): direction at `+0x000`, output at `+0x100`,
input at `+0x200`, mode (4 bits per pin) at `+0x300`.

What it showed on the 83N7: only pins 34 (camera power) and 39 (reset) follow the camera, and pin 128
is the privacy-shutter sensor (1 open, 0 closed). The indicator light is **not** a GPIO; see
`docs/hardware-notes.md`.
