{ ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Resume from swap for hibernation
  boot.resumeDevice = "/dev/disk/by-uuid/2b3272e8-6d22-414e-9646-029f14a26c17";
}
