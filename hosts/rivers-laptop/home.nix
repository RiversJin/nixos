{
  lib,
  config,
  pkgs,
  rime-ice,
  xremap,
  ...
}:

{
  imports = [
    ./home/packages.nix
    ./home/fcitx5.nix
    ./home/git.nix
    ./home/shell.nix
    ./home/dev.nix
    ./home/xremap.nix
    ./home/niri.nix
  ];

  home.stateVersion = "25.11";

  xdg.configFile."nixpkgs/config.nix".text = ''
    { allowUnfree = true; }
  '';

  xdg.configFile."fontconfig/conf.d/10-hm-fonts.conf".force = true;
}
