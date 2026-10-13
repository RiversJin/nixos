# MS-7C94 fan-control experiment

Board-scoped patch to the **Linux 7.2.9 in-tree `nct6683` source**, built as
`nct6683_msi.ko` for independent testing against the configured host kernel.
This preserves the in-tree temperature, voltage and fan-monitoring interfaces.
The module must not coexist with `nct6683` or another driver of the same EC.

Control is enabled only for:

- DMI vendor `Micro-Star International Co., Ltd.` and board
  `MAG B550M MORTAR MAX WIFI (MS-7C94)`.
- NCT6687D with an older MSI customer ID (0x0201/0x0200/0x0207).
- EC firmware 1.0, build 05/07/20.

The tested device reported customer ID **0x0201**. There are five physical
headers: CPU, pump, and three system fans. Only the first five enabled PWM
channels become writable; unused higher channels remain read-only. The
ordinary channel mapping is used, not the mapping of newer MSI DR chips.

`pwmN_enable=1` enters manual mode at the current duty cycle; `pwmN` then
accepts 0–255. Writes in automatic mode return EBUSY. `pwmN_enable=2` restores
the saved command and returns the channel to the BIOS curve. Invalid PWM and
mode values are rejected. Each update requests an EC configuration window,
waits for it to unlock, changes only the selected channel, submits the update,
and checks acceptance and readback. Polling is bounded to one second per phase.

Before a takeover the driver saves that channel's original mode and command.
Device removal/unload attempts to restore only channels still owned by it.
It does not change PWM/DC selection, BIOS temperature sources, or curve points.
Loading it does not take over any fan. There is **no userspace-death watchdog**:
after a successful manual takeover, userspace must return the channel to
automatic control or unload the module. Failed EC transactions propagate
errors; restoration is best effort if the EC stops accepting transactions.

## Build

```
nix build --offline --impure --expr '
  let f = builtins.getFlake "/home/rivers/nixos";
  in f.nixosConfigurations.rivers-host.config.boot.kernelPackages.callPackage
    /home/rivers/nixos/packages/nct6683-msi {}'
```

The package extracts this one source file from the configured kernel source,
applies the patch and uses the matching configured kernel headers and module
toolchain. It does not rebuild the whole kernel. The host boot configuration loads `nct6683_msi` and blacklists stock `nct6683`.
`host-fan-feedback.service` takes over only pwm3; its normal cleanup and
ExecStopPost return that header to BIOS control on stop or process failure.

## Live validation on 2026-10-12

The independent, time-limited systemd task loaded the patched module and
returned to the stock driver after testing. Only **pwm3/fan3** was controlled:

- Baseline: PWM 118/255, around 1250 RPM, automatic mode.
- Manual request: 143/255, around 1440 RPM.
- Returning to automatic mode: PWM returned to around 118, around 1250 RPM.
- Taking over a second time and unloading the module also restored the BIOS
  curve; the stock driver again reported around 118 and 1230 RPM.
- CPU and other headers stayed in automatic mode. The CPU fan followed its
  own firmware curve throughout. Existing BLE feedback remained healthy.
- PWM 256, mode 0, and PWM writes in automatic mode were rejected.
- No new kernel errors occurred. Loading an external module can set the
  kernel's external-module taint flag, which remains until reboot.

Raw CSV, the guarded test script and its build output are retained under
`/home/rivers/pcie-diagnostics/nct6683-msi-20261012/`.

Sources: [in-tree driver](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nct6683.c),
[nct6687d](https://github.com/Fred78290/nct6687d/blob/main/nct6687.c),
[proposed upstream DR control](https://lkml.iu.edu/2610.0/07037.html),
[MSI board specification](https://www.msi.com/Motherboard/MAG-B550M-MORTAR-MAX-WIFI/Specification).

## Persistent host case control validation

The configured host now loads this module at boot and runs the independent
Rust host controller. A bounded test at **51/255 (20%)** held fan3 at about
795–813 RPM after the initial settling sample. CPU fan mode stayed automatic.
An eight-worker, 60-second CPU SHA256 load raised Tctl from 36.75 to 58 C;
the host controller increased fan3 from 45% to 48%. The external enclosure
continued its separate switch/GPU loop. A normal service stop and SIGKILL of
its main process both returned pwm3_enable to 2; systemd then restarted the
controller successfully. Killing the entire service cgroup can also kill its
cleanup process; the preserved ownership marker allows recovery at restart.
There remains no independent kernel watchdog for a dead userspace stack.

Host load JSONL and the bounded test scripts are retained under
`/home/rivers/pcie-diagnostics/host-fan-20261012/`.
