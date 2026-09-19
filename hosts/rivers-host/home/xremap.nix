{ pkgs, xremap, ... }:

{
  imports = [
    xremap.homeManagerModules.default
  ];

  services.xremap = {
    enable = true;
    config = {
      modmap = [
        {
          name = "swap-esc-capslock";
          application = {
            not = [
              "/steam/"
              "/lutris/"
              "gamescope"
              "/wine/"
              "/proton/"
            ];
          };
          remap = {
            "CapsLock" = "Esc";
            "Esc" = "CapsLock";
          };
        }
      ];
      keymap =
        let
          terminalApplications = [
            "/(?i)^(com\\.mitchellh\\.ghostty|ghostty|org\\.kde\\.konsole|konsole|kitty|alacritty|org\\.wezfurlong\\.wezterm|wezterm|foot|xterm)$/"
          ];
        in
        [
          {
            name = "mac-style-copy-paste-in-terminals";
            exact_match = true;
            application.only = terminalApplications;
            remap = {
              "Super-c" = "C-Shift-c";
              "Super-v" = "C-Shift-v";
            };
          }
          {
            name = "mac-style-copy-paste";
            exact_match = true;
            remap = {
              "Super-c" = "C-c";
              "Super-v" = "C-v";
            };
          }
        ];
    };
  };

  # xremap only binds devices that exist when it starts.
  # Watch stable udev symlinks so keyboard hotplug rebinds automatically.
  systemd.user.services.xremap-device-refresh = {
    Unit.Description = "Restart xremap when input devices change";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl --user try-restart xremap.service";
    };
  };

  systemd.user.paths.xremap-device-watch = {
    Unit = {
      Description = "Watch /dev/input/by-id for xremap device changes";
      # Path units are ordered before paths.target/basic.target by default.
      # Ordering this after the graphical session creates a cycle with niri.
      PartOf = [ "graphical-session.target" ];
    };
    Path = {
      PathChanged = "/dev/input/by-id";
      Unit = "xremap-device-refresh.service";
      TriggerLimitIntervalSec = "10s";
      TriggerLimitBurst = 20;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
