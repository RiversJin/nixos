{ config, pkgs, ... }:

{
  # niri Wayland desktop
  programs.niri.enable = true;
  security.pam.services.swaylock = { };
  security.polkit.enable = true;
  services.upower.enable = true;
  services.udev.packages = [ pkgs.brightnessctl ];

  # Run AppImage desktop applications through NixOS's compatibility wrapper.
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${config.programs.niri.package}/bin/niri-session";
        user = "greeter";
      };
    };
  };

  # NixOS otherwise injects a stripped PATH via Environment= on niri.service.
  systemd.user.services.niri.enableDefaultPath = false;

  # Basic niri session tools
  environment.systemPackages = with pkgs; [
    alacritty
    fuzzel
    waybar
    swaybg
    swayidle
    swaylock
    xwayland-satellite
  ];

  # GVFS (SMB/network mounts)
  services.gvfs.enable = true;

  # Fonts
  fonts.packages = with pkgs; [
    maple-mono.Normal-NF-CN-unhinted
    source-han-sans
    noto-fonts-cjk-sans
  ];

  fonts.fontconfig.defaultFonts = {
    monospace = [ "Maple Mono Normal NF CN" ];
    sansSerif = [ "Source Han Sans SC" ];
    serif = [ "Source Han Sans SC" ];
  };
}
