// Lenovo Yoga 9 16N1X11 camera: Firefox's default V4L2 backend opens /dev/video0
// directly, finds only 10-bit Bayer (0 capabilities) and fails with
// "NotReadableError: Starting videoinput failed". The PipeWire backend gets
// processed frames from libcamera.
pref("media.webrtc.camera.allow-pipewire", true);
