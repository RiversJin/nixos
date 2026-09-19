# Magic Trackpad five-finger gestures

Vendored from https://github.com/natask/gestures (master snapshot retrieved
2026-09-06), under the adjacent MIT LICENSE. The exact tested source is retained
in gestures.py, with local adaptations; no moving upstream fetch occurs at build.

Five-finger pinch in toggles Noctalia's launcher; pinch out selects an empty
workspace on the focused monitor. Both commands execute on gesture end.

Changes from upstream: enable five-finger pinch recognition; keep the two-finger
translation rejection rule specific to two fingers; correct inward/outward sign;
read signed, unbuffered evdev events; load configuration from the service environment;
use normal orientation without external helpers; exit on disconnect/read failure.
The wrapper selects the Apple trackpad by name on each service start, waits when
absent, and systemd retries after Bluetooth reconnects. No exclusive device grab.

The recognition changes passed synthetic inward/outward tests and the user
confirmed both physical five-finger gestures during the temporary trial.
