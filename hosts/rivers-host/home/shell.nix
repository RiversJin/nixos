{ ... }: {
  imports = [ ../../../home/shell.nix ];
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;
}
