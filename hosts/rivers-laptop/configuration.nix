{
  config,
  pkgs,
  lib,
  unstable,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./system/boot.nix
    ./system/networking.nix
    ./system/locale.nix
    ./system/desktop.nix
    ./system/audio.nix
    ./system/packages.nix
    ./system/services.nix
    ./system/nix.nix
  ];

  # User account
  users.users.rivers = {
    isNormalUser = true;
    description = "rivers";
    shell = pkgs.zsh;
    extraGroups = [
      "networkmanager"
      "wheel"
      "video"
      "input"
      "uinput"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB88UzWy7D87cgUAvO+I/KcwrYM7XIFgBkLiOn4a6qq6 rivers@DESKTOP-5GDVV2F"
    ];
  };

  # Allow passwordless system maintenance commands.
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
        {
          command = "/run/current-system/sw/bin/nix";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  nixpkgs.config.allowUnfree = true;

  # uinput for xremap
  hardware.uinput.enable = true;

  system.stateVersion = "25.11";
}
