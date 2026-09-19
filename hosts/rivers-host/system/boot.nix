{ pkgs, ... }:

{
  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.consoleMode = "max";
  boot.loader.timeout = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules = [ "nct6683" ];
  hardware.enableAllFirmware = true;

  # AMD GPU
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
}
