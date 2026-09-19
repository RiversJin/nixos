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
    ./home/niri.nix
    ./home/fcitx5.nix
    ./home/ghostty.nix
    ./home/kitty.nix
    ./home/wezterm.nix
    ./home/git.nix
    ./home/shell.nix
    ./home/mpv.nix
    ./home/dev.nix
    ./home/dev-mirrors.nix
    ./home/neovim.nix
    ./home/xremap.nix
    ./home/codex.nix
    ./home/pizzapi.nix
    ./home/omp.nix
  ];

  home.stateVersion = "25.11";

  xdg.configFile."nixpkgs/config.nix".text = ''
    { allowUnfree = true; }
  '';

  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    setSessionVariables = true;

    desktop = "${config.home.homeDirectory}/Desktop";
    documents = "${config.home.homeDirectory}/Documents";
    download = "${config.home.homeDirectory}/Downloads";
    music = "${config.home.homeDirectory}/Music";
    pictures = "${config.home.homeDirectory}/Pictures";
    projects = null;
    publicShare = "${config.home.homeDirectory}/Public";
    templates = "${config.home.homeDirectory}/Templates";
    videos = "${config.home.homeDirectory}/Videos";
  };

  # Force overwrite HM-managed files to avoid backup conflicts
  xdg.configFile."fontconfig/conf.d/10-hm-fonts.conf".force = true;
}
