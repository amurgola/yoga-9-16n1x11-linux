# Speakers and microphones

The 83N7 has four Cirrus CS35L56 amplifiers (woofers) and a CS42L43 codec that drives the tweeters
and the headphone jack. Two things were needed for full-range, stereo, tuned sound:

1. **Amplifier firmware and tuning.** Without them the amplifiers run their ROM firmware and each
   one downmixes left and right: quiet, flat, mono. Lenovo ships the files only in the Windows Cirrus
   extension driver. They are Cirrus/Lenovo property and are **not in this repository**. Copy them
   from your own Windows installation into `cirrus-win/` next to the `PKGBUILD`:
   `C:\Windows\System32\DriverStore\FileRepository\xucsmeext_3802_fdl.inf_arm64_*\` contains
   `b0_dflt_35l56_*.wmfw` and eight `b0_dflt_SS{0,1}_3802_{LW,RW}_l1u{0,1,4,5}.bin`. The `PKGBUILD`
   installs them under the names the Linux `cs35l56` driver asks for
   (`cs35l56-b0-dsp1-misc-17aa3802-spkid{0,1}[-l1uN].{wmfw,bin}`).
2. **UCM configuration.** NVIDIA's pull request
   [alsa-ucm-conf #862](https://github.com/alsa-project/alsa-ucm-conf/pull/862) adds the
   `mt8901-soundwir` card. Fetch its files into `ucm2/`, then replace
   `HiFi-cs42l43-cs35l56x4.conf` with the one in this directory. The change: on this laptop the
   tweeters hang off the CS42L43's own speaker outputs, which the pull request never enables. The
   modified file routes them, applies Lenovo's 4.5 kHz high-pass in the codec's EQ (never feed the
   tweeters unfiltered), and moves the jack onto the same stream.

Build and install with `makepkg -si` in this directory.

Working: speakers (stereo, woofers and tweeters), internal microphones.
Not tested: headphone jack, headset microphone.

The UCM file is BSD-3-Clause, copyright NVIDIA, with local changes described in its header.
