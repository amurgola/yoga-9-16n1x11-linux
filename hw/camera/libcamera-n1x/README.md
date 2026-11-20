# libcamera 0.7.2 with a binned software ISP

`n1x-softisp-binned.patch` applies to libcamera v0.7.2 (`src/libcamera/software_isp/debayer_cpu.*`).

- **Stock behaviour:** an output smaller than the sensor is a centre crop. 1920x1200 from the
  3840x2400 OV08X40 is a 2x zoom with one tiny sensor pixel per output pixel, and all maths is 8-bit.
- **Patched:** when the output is at most half the sensor size, each output pixel is the per-colour
  average of a k x k raw block (k = 2 for 1920x1200, 3 for 1280x720). That gives the full field of
  view and less noise. Precision is 16-bit up to a 4096-entry gamma table, followed by a 3x3 luma
  denoise/sharpen with a signal-dependent threshold and chroma smoothing.
- **Live settings** in `~/.config/n1x-camera.conf`, re-read about twice a second (`n1xpower camera KEY VALUE`
  or the Power Deck sliders): `denoise`, `chroma`, `sharpen` (0..100), `contrast`, `saturation`,
  `bin` (0 = stock crop, applies at camera start).

## Building

There is no package recipe here: the build used on the test machine repackages a locally staged tree,
which is not reproducible elsewhere. Build it the usual way and replace your distribution's
`libcamera` and `libcamera-ipa` with the result:

    git clone --branch v0.7.2 https://git.libcamera.org/libcamera/libcamera.git
    cd libcamera && patch -p1 < ../n1x-softisp-binned.patch
    meson setup build -Dwerror=false \
      -Dpipelines=imx8-isi,mali-c55,rkisp1,rpi/pisp,rpi/vc4,simple,uvcvideo,vimc \
      -Dipas=mali-c55,rkisp1,rpi/pisp,rpi/vc4,simple,vimc
    meson compile -C build

`-Dwerror=false` is needed with GCC 16 (an array-bounds warning in unrelated code). Keep the package
manager from replacing the build afterwards (on Arch: `IgnorePkg = libcamera libcamera-ipa`).

## Cost

Measured in a dim room: 30 fps at 1920x1200 and at 1280x720; about 1.5 CPU cores at 1920x1200
(the stock crop path uses 0.7). Most of that is the bulk copy of the full-resolution frame out of
uncached camera memory; reading that memory element by element instead dropped to 3.75 fps.
