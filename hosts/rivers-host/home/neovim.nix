{ neovimConfig, pkgs, ... }:

{
  home.packages = [
    neovimConfig.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
