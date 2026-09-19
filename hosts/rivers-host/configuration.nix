{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ../../modules/zellij-web.nix
    ./hardware-configuration.nix
    ./system/boot.nix
    ./system/networking.nix
    ./system/locale.nix
    ./system/desktop.nix
    ./system/niri.nix
    ./system/display-power.nix
    ./system/audio.nix
    ./system/packages.nix
    ./system/mihomo.nix
    ./system/gaming.nix
    ./system/hid.nix
    ./system/powercap.nix
    ./system/virtualisation.nix
    ./system/services.nix
    ./system/nix.nix
  ];

  # User account
  users.users.rivers = {
    isNormalUser = true;
    description = "rivers";
    shell = pkgs.zsh;
    linger = true;
    extraGroups = [
      "networkmanager"
      "wheel"
      "video"
      "render"
      "i2c"
      "input"
      "uinput"
      "kvm"
      "libvirtd"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB88UzWy7D87cgUAvO+I/KcwrYM7XIFgBkLiOn4a6qq6 rivers@DESKTOP-5GDVV2F"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILn0UgDdOPHnzyxgMMvfrXp1RdCRN63fHw4x7SbTZ9LW nix-builder-to-rivers-host-2026-07-06"
    ];
  };

  # Allow passwordless nixos-rebuild and systemctl
  security.sudo.extraRules = [
    {
      users = [ "rivers" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # ROCm / OpenCL support for AMD GPU
  hardware.amdgpu.opencl.enable = true;

  # uinput for xremap
  hardware.uinput.enable = true;

  # DDC/CI for external monitor brightness control
  hardware.i2c.enable = true;

  system.stateVersion = "25.11";
}
