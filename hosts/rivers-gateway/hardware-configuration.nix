{ config, lib, pkgs, modulesPath, ... }:

{

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  # The external it87 module depends on hwmon-vid. Load it from a regular
  # service below because systemd-modules-load runs too early for its custom
  # modprobe install command during boot.
  boot.kernelModules = [ "kvm-amd" "hwmon-vid" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.it87 ];

  systemd.services.load-external-it87 = {
    description = "Load the external IT8613E-capable it87 module";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "monitor-disk-temperatures.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "load-external-it87" ''
        if ! ${pkgs.gnugrep}/bin/grep -q '^it87 ' /proc/modules; then
          ${pkgs.kmod}/bin/insmod ${config.boot.kernelPackages.it87}/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/kernel/drivers/hwmon/it87.ko
        fi
      '';
    };
  };
  boot.blacklistedKernelModules = [ "amd_sfh" ];


  fileSystems."/" =
    { device = "/dev/disk/by-uuid/982b0ed8-7782-431a-bb7c-34df6ef9d51c";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/A64A-0F65";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  fileSystems."/mnt/hdd0" =
    { device = "/dev/disk/by-uuid/fe3e0e00-bdea-4636-ae70-291379fc8bb3";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "space_cache=v2" "autodefrag" ];
    };

  fileSystems."/mnt/hdd1" =
    { device = "/dev/disk/by-label/HDD1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd:1" "space_cache=v2" "nofail" ];
    };

  swapDevices = [ ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.eno1.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp3s0.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp4s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
