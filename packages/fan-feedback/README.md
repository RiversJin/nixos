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

GPU runtime suspend is a valid power state, not a sensor fault. When the
configured GPU's amdgpu hwmon still exists and `power/runtime_status` explicitly
reports `suspended`, its cooling request returns to the baseline; switch and
other active GPU monitoring continue, including the existing assistance hold.
Status marks that GPU `runtime_status: suspended` and reports unavailable
RPM/temperature/power as `null`, not zero. The reader checks runtime state again
after active hwmon reads, so suspension racing with a read is recognized too.
Suspend/resume transitions are retried for up to 500 ms; a persistent transition,
unknown/missing runtime state, missing hwmon, or unreadable/invalid active GPU
sensor still triggers fallback. Waking restores complete readings and thermal
guards on the next sample. Sampling never changes PCIe power settings or wakes
a sleeping card to obtain readings.

GPU assistance requires 20 seconds of sustained demand and holds increased
airflow for 120 seconds after demand declines. Ordinary changes are limited
to +5 percentage points per 15 seconds or -2 per 60 seconds, with a small
deadband. Switch >=80 C or GPU edge >=80 C / junction >=95 C immediately
requests at least 80%; switch >=90 C or GPU edge >=85 C / junction >=100 C
requests 100%, overriding presence and smoothing. The GPU guards precede
the observed driver critical limits of edge 100 C / junction 110 C.

Any missing/invalid required switch or GPU telemetry requests fallback PWM
(configured as 100%) and requires 60 seconds of continuously healthy readings
to recover. It then enters `sensor-recovery-ramp`: at most -10 percentage points
per 5 seconds, bounded by switch demand, held GPU assistance and current GPU
demand. High-temperature guards still override recovery. Another sensor fault
immediately requests fallback and restarts the healthy window. Recovery from
100% to a steady 30% takes about 90–100 seconds including the healthy window,
instead of roughly 35 minutes. Ordinary -2 points/minute decay resumes after
recovery. A connection starting at fallback PWM uses the same recovery path.
Fan RPM below 300 for three samples, stale BLE telemetry, or external changes
to the controller parameters end the session and trigger fallback/reconnection.
Every write is confirmed against fresh notifications and preserves all eleven
controller parameter bytes. A safe normal stop restores the initial state;
an unsafe stop requests fallback. Calibration has stricter thermal guards.

Bluetooth loss is a physical limitation: the controller retains its last PWM.
Software cannot guarantee a new full-speed command while the BLE link is down;
no device-side disconnect watchdog has been verified. Status explicitly reports
disconnection and whether fallback was confirmed. Failed or timed-out Connect
attempts also run disconnect cleanup, so a late successful connection does not
leave subsequent retries falsely reporting another client owns the device.

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

## Separate host case

The CPU/memory host case is physically separate from the switch/GPU enclosure.
`host-fan-feedback.service` controls only motherboard **pwm1/fan1**, with its
own process, sensor loop and crash recovery. On the ASUS ROG STRIX B850-A GAMING
WIFI7 S NEO, isolated full-speed tests and physical observation confirmed fan1
is the case fan and fan2 is the CPU fan. CPU and pump fan control stays with
BIOS. The daemon checks exact board DMI identity and refuses every channel
except 1. The two daemons share desktop presence and the mode override.

The Super-I/O ID is 0xd806 (NCT6701D); Linux 7.2.9 exposes its compatible
interface as `nct6799` through the stock `nct6775` driver at
`/sys/devices/platform/nct6775.656/hwmon`. No force_id or ACPI resource override
is needed. The MSI-specific driver is no longer loaded.

Quiet mode has a **20% minimum**. CPU Tctl 45/55/65/75/80/85 C requests
20/45/60/75/85/100%; maximum DDR5 SPD temperature 40/45/50/55/60/65 C requests
20/45/60/75/85/100%. Away/cool mode has a 45% minimum. Temperatures are
smoothed independently: CPU uses a 60-second time constant to suppress short
junction-temperature bursts, while memory retains 15 seconds. Elevated
demand persists for 120 seconds. Ordinary CPU-driven increases are limited to
+3 points/30 seconds; a memory request covering the full held target retains
+5 points/15 seconds. Decreases remain -2 points/60 seconds. Raw CPU >=80 C or
memory >=60 C immediately requests at least 85%; CPU >=85 C or memory >=65 C
requests 100%. These are conservative control thresholds, not chip ratings.

Memory input requires both installed DIMMs' enabled `spd5118` digital sensors;
a missing, disabled or invalid sensor is a fault. It does not use the unverified
analog temperature labels of the NCT6799 compatibility interface. The host
loop does not use switch or GPU load. RPM <300 for three samples, invalid
sensors, or a failed write ends the session and restores BIOS before restarting.

The narrowly scoped udev rule grants `rivers` only pwm1 and pwm1_enable write
access. Board identity, channel and the original automatic mode are recorded
atomically before takeover. Normal exit restores that exact mode (currently
Smart Fan IV / 5), and systemd ExecStopPost does the same after a crash,
including SIGKILL. Legacy or mismatched ownership markers are rejected.
Restoration also publishes `restored-bios` status, so the restart delay does not
leave the last manual-control snapshot visible after a crash.
Takeover initializes manual PWM from the current automatic output, rather than
reviving a previous full-speed manual command stored in the chip.
The kernel reports manual full speed (255/255) as pwm_enable=0; this is accepted
as full-speed control rather than treated as an external mode change.
The kernel module has no independent userspace-death watchdog.

```
fan-feedback host-status
journalctl -u host-fan-feedback.service
```

`fan-feedback status` also includes host case status. Stopping the host service
returns fan1 to BIOS; it does not stop the BLE enclosure controller.
