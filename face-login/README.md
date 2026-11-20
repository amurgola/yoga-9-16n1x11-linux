# Face login with Howdy on the IR camera

[Howdy](https://github.com/boltgolt/howdy) 3.0.2 by boltgolt, using the laptop's infrared camera
through the driver in `hw/camera/`. This is a record of the setup on the test machine, not an
installer.

**Read first.** Infrared face matching is a convenience, not a stronger lock. It is easier to fool
than a good password and weaker than Windows Hello, which adds depth checks. The password keeps
working everywhere and remains the real credential.

Howdy 3.0.2 has no telemetry and no network code at run time (its source was read before building).
The only downloads are at install time: the Python libraries and three public dlib model files.

## Build

Howdy's Python parts live in a private, root-owned environment so that no system package changes:

    sudo install -d -o "$USER" /opt/howdy-venv && python3 -m venv /opt/howdy-venv
    /opt/howdy-venv/bin/pip install --only-binary=:all: numpy opencv-python-headless
    /opt/howdy-venv/bin/pip install --no-binary dlib dlib          # compiles for several minutes

    git clone --branch v3.0.2 https://github.com/boltgolt/howdy && cd howdy/howdy
    meson setup build --prefix=/usr --sysconfdir=/etc --libdir=lib \
        -Dpython_path=/opt/howdy-venv/bin/python
    meson compile -C build && sudo meson install -C build
    sudo chown -R root:root /opt/howdy-venv          # PAM runs this as root: it must not be user-writable

Download the three model files named in `/usr/share/dlib-data/install.sh` into `/usr/share/dlib-data/`.
Build dependencies on Arch: `meson`, `ninja`, `libinih`, `libevdev`, `pam`.

A Python minor-version upgrade breaks the environment; rebuild it. Until then logins fall back to
the password.

## Configuration

`/etc/howdy/config.ini`:

    device_path = /dev/v4l/by-path/platform-n1x-yoga-cam.1-video-index0
    timeout_notice = false

Enrol with `sudo howdy -U <user> add`. Enrol once in daylight and once in evening light: a single
daylight model matched only about half the time under a lamp.

## PAM

In every case Howdy comes first and the unchanged password stack follows.

- **sudo** (`/etc/pam.d/sudo`) and **SDDM login** (`/etc/pam.d/sddm`): add as the first `auth` line

      auth  sufficient  pam_howdy.so

  After a face login at SDDM the KDE wallet stays locked until the password is typed once.
- **KDE lock screen:** install `kde-fingerprint` from this directory as `/etc/pam.d/kde-fingerprint`.
  Do **not** put Howdy into the `kde` password stack: Plasma starts that stack once, when the screen
  locks, so nothing looks for a face after a resume. The `kde-fingerprint` stack is the lock screen's
  background method. It runs while the password page is showing and unlocks without a confirmation
  button. The password page appears on the first key press or pointer movement.

Before editing PAM files, arm an automatic revert in case sudo stops working, for example:

    sudo cp -a /etc/pam.d/sudo /etc/pam.d/sudo.bak
    sudo systemd-run --on-active=300 sh -c '[ -e /run/pam-ok ] || cp -a /etc/pam.d/sudo.bak /etc/pam.d/sudo'
    # ... edit, test in a new terminal, then: sudo touch /run/pam-ok

## Behaviour worth knowing

- Recognition takes about one second.
- Howdy skips itself with the lid closed and in SSH sessions.
- The webcam and the IR camera share one capture path. While the webcam streams, the IR camera
  cannot start and Howdy falls through to the password.
- The IR sensor's auto exposure overexposed the face in a dark room until its target was lowered
  (`ir_ae_target`, see `hw/camera/n1x-cam/README.md`).
