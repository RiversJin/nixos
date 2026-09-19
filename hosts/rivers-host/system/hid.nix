{ pkgs, ... }:

{
  # Keep the DeepCool ASSASSIN-IV-VC-VISION display updated.
  services.hardware.deepcool-digital-linux.enable = true;
  systemd.services.deepcool-digital-linux = {
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig.RestartSec = "5s";
  };

  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "keyboard-webhid-udev-rules";
      destination = "/lib/udev/rules.d/60-keyboard-webhid.rules";
      text = ''
        # Allow Chromium WebHID apps such as Keychron Launcher to open the K8 Max.
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3434", ATTRS{idProduct}=="0a80", TAG+="uaccess", TAG+="udev-acl"

        # The firmware updater reboots the keyboard into STM32 DFU mode.
        SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="df11", TAG+="uaccess", TAG+="udev-acl"

        # Allow browser-based configurators to open the MCHOSE G87 in wired mode.
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="41e4", ATTRS{idProduct}=="2201", TAG+="uaccess", TAG+="udev-acl"

        # Allow the Adafruit Feather nRF52840 Express serial console.
        KERNEL=="ttyACM*", SUBSYSTEM=="tty", ATTRS{idVendor}=="239a", ATTRS{idProduct}=="8029", TAG+="uaccess", TAG+="udev-acl", ENV{ID_MM_DEVICE_IGNORE}="1"
      '';
    })
  ];
}
