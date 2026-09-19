{ ... }: {
  imports = [ ../../../modules/desktop/services.nix ];
  # Power management (GNOME integrates with power-profiles-daemon by default)
  services.power-profiles-daemon.enable = true;

  # Laptop lid/power button handling
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "lock";
  };
}
