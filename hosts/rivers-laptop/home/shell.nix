{ pkgs, ... }: {
  imports = [ ../../../home/shell.nix ];
  home.packages = [ pkgs.zellij ];
}
