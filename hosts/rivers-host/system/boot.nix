{ pkgs, ... }:

{
  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.consoleMode = "max";
  boot.loader.timeout = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Allow PCIe P2P routing globally. ACS redirection through the CPU root port
  # breaks peer reads on this host; pci:0:0 matches every PCI device.
  # Configure this during PCI initialization so resume restores the same policy.
  boot.kernelParams = [ "pci=disable_acs_redir=pci:0:0" ];
  boot.kernelPatches = [
    {
      # Same GPU ID does not imply the same board VBIOS on this dual-XTX host.
      name = "amdgpu-vfct-exact-pci-match";
      patch = ../patches/amdgpu-vfct-exact-pci-match.patch;
    }
  ];
  boot.kernelModules = [ "nct6683" ];
  hardware.enableAllFirmware = true;

  # AMD GPU
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
}
