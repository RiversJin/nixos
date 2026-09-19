{ config, pkgs, ... }:

{
  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${config.programs.niri.package}/bin/niri-session";
      user = "greeter";
    };
  };

  # greetd's PAM stack includes login; pass the login password to the keyring.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
  services.xserver.enable = true;
  services.udisks2.enable = true;
  services.upower.enable = true;
  programs.dconf.enable = true;
  xdg.icons.enable = true;

  # GVFS (SMB/network mounts)
  services.gvfs.enable = true;

  # Fonts
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    maple-mono.Normal-NF-CN-unhinted
    source-han-sans
  ];

  fonts.fontconfig.defaultFonts = {
    monospace = [ "Maple Mono Normal NF CN" ];
    sansSerif = [
      "Noto Sans"
      "Noto Sans CJK SC"
    ];
    serif = [
      "Noto Serif"
      "Noto Serif CJK SC"
    ];
  };
}
