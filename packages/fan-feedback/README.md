# fan-feedback

Small blocking Rust daemon for the HC-F147-1 BLE controller, PEX88096 hwmon
sensor, and two RX 7900 XTX cards. The controller drives both the switch fan and
case fans; its tachometer reports one channel, not every attached fan.

Every five seconds the daemon samples the switch and both GPUs by PCI address.
GPU fans remain under the cards' own automatic control. The daemon takes the
highest cooling request across all devices; it never adds their percentages.

## Policy

Quiet switch curve (linear interpolation): at or below 65 C, 30%; 70 C, 45%;
75 C, 65%; 80 C, 80%; 90 C, 100%. Away mode holds at least 35% and starts ramping above 55 C,
reaching 45% at 65 C; from 75 C its curve matches quiet mode. These are cooling
thresholds, not a request to deliberately heat a cooler chip to 65 C.

Each GPU's actual RPM is divided by its `fan1_max`. The case fan request is
30% at 0–20% GPU fan speed, 45% at 35%, 55% at 50%, 70% at 65%, 85% at 80%,
and 100% at 100%. GPU temperatures also request airflow: edge 60/70/80/85 C
maps to 30/45/80/100%; junction 75/85/95/100 C maps to 30/50/80/100%.
A stopped GPU fan is valid telemetry. GPU busy and power are diagnostic only.

GPU assistance requires 20 seconds of sustained demand and holds increased
airflow for 120 seconds after demand declines. Ordinary changes are limited
to +5 percentage points per 15 seconds or -2 per 60 seconds, with a small
deadband. Switch >=80 C or GPU edge >=80 C / junction >=95 C immediately
requests at least 80%; switch >=90 C or GPU edge >=85 C / junction >=100 C
requests 100%, overriding presence and smoothing. The GPU guards precede
the observed driver critical limits of edge 100 C / junction 110 C.

Any missing/invalid required switch or GPU telemetry requests fallback PWM
(configured as 100%) and requires 60 seconds of healthy readings to recover.
Fan RPM below 300 for three samples, stale BLE telemetry, or external changes
to the controller parameters end the session and trigger fallback/reconnection.
Every write is confirmed against fresh notifications and preserves all eleven
controller parameter bytes. A safe normal stop restores the initial state;
an unsafe stop requests fallback. Calibration has stricter thermal guards.

Bluetooth loss is a physical limitation: the controller retains its last PWM.
Software cannot guarantee a new full-speed command while the BLE link is down;
no device-side disconnect watchdog has been verified. Status explicitly reports
disconnection and whether fallback was confirmed.

## Operation

NixOS installs `/etc/fan-feedback.conf` and enables `fan-feedback.service`.
The daemon runs as `rivers`, reads sysfs, and writes through BlueZ's system bus.
`niri-fan-presence.service` writes a runtime presence file: after 15 minutes of
desktop input inactivity it selects the away curve, resuming quiet on activity.
This measures desktop activity, not physical occupancy. Missing presence data
defaults to quiet; thermal guards always override it.

```
fan-feedback status
fan-feedback mode auto
fan-feedback mode quiet
fan-feedback mode cool
journalctl -u fan-feedback.service
```

`status` reports actual PWM/tachometer, switch temperature, each GPU's RPM,
temperatures and requested PWM, the filtered GPU assistance, and sample age.
Samples older than 30 seconds return a nonzero status. Mode overrides live in
`/run/fan-feedback` and reset after reboot; default mode is auto.

`probe` and `calibrate PWM:seconds,...` require the daemon to be stopped because
the device connection is exclusive. Calibration logs JSONL and restores the
initial parameters and mode when thermally safe. Neither tool changes GPU fan
control or PCIe power settings.
