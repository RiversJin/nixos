{ pkgs, ... }:

{
  # Allow btop and other tools to read Intel RAPL power consumption data
  # by making energy_uj world-readable (default is root-only).
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "powercap-intel-rapl-udev-rules";
      destination = "/lib/udev/rules.d/60-powercap-intel-rapl.rules";
      text = ''
        SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", ACTION=="add|change", RUN+="${pkgs.coreutils}/bin/chmod a+r /sys/class/powercap/%k/energy_uj"
      '';
    })
  ];
}
